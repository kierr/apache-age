# typed: strong
# frozen_string_literal: true

require 'json'

require 'pg'


module ApacheAge
  # Standalone bulk loading for Apache AGE. No Rails dependency — pg gem only.
  #
  # Three strategies ranked by performance and correctness:
  #   :insert_select — primary. Server-side INSERT ... SELECT into per-label tables.
  #                    Best when source data is already in PG. ~9,500 rows/sec.
  #   :copy_stdin    — alternative. COPY FROM STDIN into per-label tables.
  #                    Best for non-PG sources (CSV, external APIs). ~9,500 rows/sec.
  #   :cypher_merge  — fallback. Batch Cypher MERGE. Slow (~80 rows/sec) but idempotent.
  #                    For datasets < 100K rows only.
  #
  # Per-label tables (created via create_vlabel) inherit from _ag_label_vertex/_ag_label_edge
  # and have their own PK index and sequence. Always target per-label tables, never the
  # parent _ag_label_vertex directly (it has no PK, no trigger, no index).
  #
  # See ADR-0151 for the full strategy decision and rejection reasons for alternatives.
  #
  # RATIONALE: DYNAMIC-BOUNDARY: ApacheAge::BulkLoad crosses two untyped edges: pg gem RBIs declare PG::Connection#exec_params/#exec as returning T.untyped (typed shim wraps each call site to restore PG::Result), and per-label statistics hashes are T::Hash[Symbol, T.untyped] (mixed Integer/String/Float count/progress/speed values). T.untyped is the boundary type at each edge. Would need typed pg gem RBIs and a typed LabelInfo/Stats struct to remove.
  module BulkLoad
    CYPHER_BATCH_LIMIT = 200
    DEFAULT_BATCH_SIZE = 100_000
    ENTRY_ID_BITS = 48

    class BulkLoadError < StandardError; end

    # Typed wrapper around PG::Connection#exec — tapioca's RBI declares exec
    # as returning T.untyped, producing 7018 at typed:strong. This helper
    # T.casts the result so all downstream method calls (ntuples, first, [])
    # resolve through the custom PG::Result RBI shim.
    sig { params(conn: PG::Connection, sql: String, binds: T.nilable(T::Array[T.untyped])).returns(PG::Result) }
    def self.query(conn, sql, binds = nil)
      result = binds ? conn.exec(sql, binds) : conn.exec(sql)
      T.cast(result, PG::Result)
    end

    # RATIONALE: Sorbet resolves bare Integer() as a module method (7003) in module_function scopes.
    #   String#to_i supports base and avoids the kernel method resolution issue.
    #   Would need Sorbet to resolve Kernel methods in module_function scopes to reconsider.
    sig { params(value: T.nilable(T.any(String, Integer, Float)), base: T.nilable(Integer)).returns(Integer) }
    def self.parse_int(value, base = nil)
      return 0 if value.nil?

      if base && value.is_a?(String)
        value.to_i(base)
      else
        # Kernel-scoped to avoid Sorbet 7003 (module_method resolution in module_function
        # scopes); no base arg, since Integer(value, 10) raises ArgumentError for the
        # Integer/Float inputs this branch accepts (base is only valid for String).
        Kernel.Integer(value)
      end
    end

    module_function



    # --- GraphAdmin: graph and label lifecycle ---

    module GraphAdmin
      module_function

      sig { params(conn: PG::Connection, graph_name: String).void }
      def ensure_graph!(conn, graph_name)
        validate_identifier!(graph_name)
        BulkLoad.query(conn, "LOAD 'age'")
        BulkLoad.query(conn, 'SET search_path = ag_catalog, "$user", public')
        exists = BulkLoad.parse_int(BulkLoad.query(conn, 'SELECT count(*) FROM ag_catalog.ag_graph WHERE name = $1', [graph_name]).first['count'],
                                    10).positive?
        return if exists

        BulkLoad.query(conn, 'SELECT ag_catalog.create_graph($1)', [graph_name])
      ensure
        begin
          BulkLoad.query(conn, 'SET search_path = "$user", public')
        rescue PG::Error
          nil
        end
      end

      sig { params(conn: PG::Connection, graph_name: String, label_name: String).returns(Integer) }
      def ensure_vlabel!(conn, graph_name, label_name)
        validate_identifier!(label_name)
        existing = BulkLoad.query(conn, 'SELECT id FROM ag_catalog.ag_label WHERE name = $1', [label_name])
        label_id = if existing.ntuples.zero?
                     BulkLoad.query(conn, "LOAD 'age'")
                     BulkLoad.query(conn, 'SET search_path = ag_catalog, "$user", public')
                     BulkLoad.query(conn, 'SELECT create_vlabel($1, $2)', [graph_name, label_name])
                     T.cast(label_info(conn, label_name).fetch(:id), Integer)
                   else
                     BulkLoad.parse_int(existing.first['id'], 10)
                   end
        # Always ensure the GIN index, even for pre-existing labels: AGE compiles
        # `MATCH (v {object_id: ...})` to `properties @> ...` run as a seq scan, so
        # without gin_agtype_ops every property lookup is a full table scan. New
        # empty labels index instantly; populated labels index once under a brief
        # SHARE lock. Idempotent via IF NOT EXISTS.
        ensure_vertex_gin_index!(conn, graph_name, label_name)
        label_id
      ensure
        begin
          BulkLoad.query(conn, 'SET search_path = "$user", public')
        rescue PG::Error
          nil
        end
        nil
      end

      sig { params(conn: PG::Connection, graph_name: String, label_name: String).void }
      def ensure_vertex_gin_index!(conn, graph_name, label_name)
        validate_identifier!(label_name)
        qualified = quote_qualified(graph_name, label_name)
        index_name = quote_ident("idx_#{label_name.downcase}_properties_gin")
        BulkLoad.query(conn, "CREATE INDEX IF NOT EXISTS #{index_name} ON #{qualified} USING GIN (properties)")
      rescue PG::Error => e
        # Index creation is a performance optimization, not a correctness
        # requirement — a transient failure must not abort the bulk load.
        # logged via ApacheAge.logger, which dispatches to SemanticLogger when available.
        ApacheAge.logger.warn(
          'age_graph.bulk_load.gin_index_ensure_failed',
          label_name: label_name, error_class: e.class.name, error_message: e.message
        )
      end

      sig { params(conn: PG::Connection, graph_name: String, label_name: String).void }
      def ensure_elabel!(conn, graph_name, label_name)
        validate_identifier!(label_name)
        existing = BulkLoad.query(conn, 'SELECT id FROM ag_catalog.ag_label WHERE name = $1', [label_name])
        return if existing.ntuples.positive?

        BulkLoad.query(conn, "LOAD 'age'")
        BulkLoad.query(conn, 'SET search_path = ag_catalog, "$user", public')
        BulkLoad.query(conn, 'SELECT create_elabel($1, $2)', [graph_name, label_name])
      ensure
        begin
          BulkLoad.query(conn, 'SET search_path = "$user", public')
        rescue PG::Error
          nil
        end
      end

      sig { params(conn: PG::Connection, label_name: String).returns(T::Hash[Symbol, T.untyped]) }
      def label_info(conn, label_name)
        row = BulkLoad.query(conn,
                             'SELECT id, name, kind, relation::regclass::text AS relation, seq_name FROM ag_catalog.ag_label WHERE name = $1',
                             [label_name])
        Kernel.raise BulkLoadError, "Label '#{label_name}' not found" if row.ntuples.zero?

        r = row.first
        { id: BulkLoad.parse_int(r['id'], 10), name: r['name'], kind: r['kind'], relation: r['relation'], seq_name: r['seq_name'] }
      end

      LabelInfo = T.type_alias { T::Hash[Symbol, T.untyped] }

      sig { params(conn: PG::Connection).returns(T::Array[LabelInfo]) }
      def labels(conn)
        BulkLoad.query(conn,
                       'SELECT id, name, kind, relation::regclass::text AS relation, seq_name FROM ag_catalog.ag_label ORDER BY id').map do |r|
          { id: BulkLoad.parse_int(r['id'], 10), name: T.must(r['name']), kind: T.must(r['kind']), relation: T.must(r['relation']),
            seq_name: T.must(r['seq_name']) }
        end
      end

      # Deletes all rows from every per-label table in the graph.
      # RATIONALE: Uses DELETE rather than TRUNCATE because TRUNCATE on inherited tables
      # cascades to siblings. DELETE is per-table and respects the per-label PK.
      # For initial migration with no concurrent access, TRUNCATE would also work,
      # but DELETE is safer in case anything else has written to the graph.
      sig { params(conn: PG::Connection, graph_name: String).void }
      def truncate_graph!(conn, graph_name)
        validate_identifier!(graph_name)
        labels(conn).each do |lbl|
          name = T.cast(lbl[:name], String)
          next if name.start_with?('_ag_label_')

          BulkLoad.query(conn, "DELETE FROM #{quote_qualified(graph_name, name)}")
          # Reset sequences
          seq = T.cast(lbl[:seq_name], String)
          BulkLoad.query(conn, "SELECT setval('#{quote_ident(graph_name)}.#{quote_ident(seq)}', 1, false)")
        end
      end

      sig { params(name: String).void }
      def validate_identifier!(name)
        return if name.match?(/\A[a-z_][a-z0-9_]*\z/i)

        Kernel.raise ArgumentError, "Invalid AGE identifier '#{name}'"
      end

      sig { params(name: String).returns(String) }
      def quote_ident(name)
        name.match?(/\A[a-z_][a-z0-9_]*\z/i) ? "\"#{name}\"" : name
      end

      sig { params(schema: String, name: String).returns(String) }
      def quote_qualified(schema, name)
        "#{quote_ident(schema)}.#{quote_ident(name)}"
      end
    end

    # --- VertexLoader: bulk vertex creation ---

    module VertexLoader
      module_function

      # Loads vertices from _migration_pk_map into a per-label table.
      #
      # Options:
      #   strategy:     :insert_select | :copy_stdin | :cypher_merge
      #   graph_name:   AGE graph name (e.g., 'autosis')
      #   label_name:   per-type label (e.g., 'Person')
      #   table_name:   _migration_pk_map table_name filter (e.g., 'person_entities')
      #   object_type:  value for object_type property (e.g., 'person')
      #   batch_size:   rows per batch (default 100K)
      #   progress_key: key in progress table for resumability
      #
      # Returns { created:, elapsed_seconds: }
      sig do
        params(conn: PG::Connection, strategy: Symbol, graph_name: String, label_name: String,
               table_name: String, object_type: String, batch_size: Integer,
               progress_key: T.nilable(String)).returns(T::Hash[Symbol, T.untyped])
      end
      def load(conn, strategy:, graph_name:, label_name:, table_name:, object_type:, batch_size: DEFAULT_BATCH_SIZE, progress_key: nil)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        label = GraphAdmin.label_info(conn, label_name)
        total = T.let(0, Integer)

        case strategy
        when :insert_select
          total = load_insert_select(conn, graph_name:, label_name:, label:, table_name:, object_type:, batch_size:, progress_key:)
        when :copy_stdin
          total = load_copy_stdin(conn, graph_name:, label_name:, label:, table_name:, object_type:, batch_size:, progress_key:)
        when :cypher_merge
          total = load_cypher_merge(conn, graph_name:, label_name:, table_name:, object_type:, batch_size:, progress_key:)
        else
          Kernel.raise ArgumentError, "Unknown strategy: #{strategy}"
        end

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        { created: total, elapsed_seconds: elapsed }
      end

      sig do
        params(conn: PG::Connection, graph_name: String, label_name: String, label: T::Hash[Symbol, T.untyped],
               table_name: String, object_type: String, batch_size: Integer,
               progress_key: T.nilable(String)).returns(Integer)
      end
      def load_insert_select(conn, graph_name:, label_name:, label:, table_name:, object_type:, batch_size:, progress_key:)
        qualified = GraphAdmin.quote_qualified(graph_name, label_name)
        seq_name = "#{GraphAdmin.quote_ident(graph_name)}.#{GraphAdmin.quote_ident(T.cast(label[:seq_name], String))}"
        total = T.let(0, Integer)

        Kernel.loop do
          last_uuid = progress_key ? ProgressTracker.load_progress(conn, progress_key) : nil
          where = last_uuid ? "AND new_id > '#{escape_uuid(last_uuid)}'" : ''

          sql = <<~SQL.squish
            INSERT INTO #{qualified} (id, properties)
            SELECT
              ag_catalog._graphid(
                #{T.cast(label[:id], Integer)},
                nextval('#{seq_name}')
              ),
              ag_catalog.agtype_build_map(
                'object_id', sub.new_id::text,
                'object_type', '#{object_type}'
              )
            FROM (
              SELECT new_id FROM _migration_pk_map
              WHERE table_name = '#{table_name}'
              #{where}
              ORDER BY new_id
              LIMIT #{batch_size}
            ) sub
            ON CONFLICT DO NOTHING
          SQL

          result = BulkLoad.query(conn, sql)
          inserted = result.cmd_tuples
          total += inserted

          break if inserted.zero?

          last_row = BulkLoad.query(conn,
                                    "SELECT new_id FROM _migration_pk_map WHERE table_name = '#{table_name}' " \
                                    "#{where} ORDER BY new_id LIMIT #{batch_size}")
          if last_row.ntuples.positive? && progress_key
            last_new_id = T.must(last_row[last_row.ntuples - 1]['new_id'])
            ProgressTracker.save_progress(conn, progress_key, last_new_id, total)
          end

          ApacheAge.logger.info("[vertices] #{label_name}: #{total} rows (#{inserted} this batch)")
        end

        total
      end

      sig do
        params(conn: PG::Connection, graph_name: String, label_name: String, label: T::Hash[Symbol, T.untyped],
               table_name: String, object_type: String, batch_size: Integer,
               progress_key: T.nilable(String)).returns(Integer)
      end
      def load_copy_stdin(conn, graph_name:, label_name:, label:, table_name:, object_type:, batch_size:, progress_key:)
        # COPY batches are consumed strictly via the progress cursor: without one the loop
        # re-selects the same first batch every iteration and spins forever, so a cursor
        # is required rather than optional (the only strategy that can terminate without
        # one is :insert_select, whose break keys on conflict-driven zero inserts).
        Kernel.raise ArgumentError, 'progress_key is required for :copy_stdin — the batch loop cannot advance without a cursor' if progress_key.nil?

        qualified = GraphAdmin.quote_qualified(graph_name, label_name)
        label_id = T.cast(label[:id], Integer)
        seq_name = "#{GraphAdmin.quote_ident(graph_name)}.#{GraphAdmin.quote_ident(T.cast(label[:seq_name], String))}"
        total = T.let(0, Integer)

        Kernel.loop do
          # The raise guard proves progress_key non-nil here; the ternary's nil
          # branch was dead code Sorbet flagged unreachable.
          last_uuid = ProgressTracker.load_progress(conn, T.must(progress_key))
          where = last_uuid ? "AND new_id > '#{escape_uuid(last_uuid)}'" : ''
          rows = BulkLoad.query(conn,
                                "SELECT new_id FROM _migration_pk_map WHERE table_name = '#{table_name}' #{where} ORDER BY new_id LIMIT #{batch_size}")
          break if rows.ntuples.zero?

          start_entry = reserve_sequence_range(conn, seq_name)
          batch_count = write_copy_batch(conn, qualified:, rows:, start_entry:, label_id:, object_type:)
          BulkLoad.query(conn, "SELECT setval('#{seq_name}', #{start_entry + batch_count - 1}, true)")
          total += batch_count

          track_vertex_progress(conn, progress_key:, rows:, total:, label_name:, batch_count:)
        end

        total
      end

      sig { params(conn: PG::Connection, progress_key: T.nilable(String), rows: PG::Result, total: Integer, label_name: String, batch_count: Integer).void }
      def track_vertex_progress(conn, progress_key:, rows:, total:, label_name:, batch_count:)
        last_row = rows[rows.ntuples - 1]
        ProgressTracker.save_progress(conn, progress_key, T.must(last_row['new_id']), total) if progress_key
        ApacheAge.logger.info("[vertices] #{label_name}: #{total} rows (#{batch_count} this batch)")
      end

      sig { params(conn: PG::Connection, seq_name: String).returns(Integer) }
      def reserve_sequence_range(conn, seq_name)
        start_entry = BulkLoad.parse_int(BulkLoad.query(conn, "SELECT nextval('#{seq_name}')").first['nextval'], 10)
        BulkLoad.query(conn, "SELECT setval('#{seq_name}', #{start_entry - 1}, false)")
        start_entry
      end

      sig { params(conn: PG::Connection, qualified: String, rows: PG::Result, start_entry: Integer, label_id: Integer, object_type: String).returns(Integer) }
      def write_copy_batch(conn, qualified:, rows:, start_entry:, label_id:, object_type:)
        batch_count = 0
        conn.copy_data("COPY #{qualified} FROM STDIN (FORMAT CSV)") do |copy|
          rows.each_with_index do |row, idx|
            entry_id = start_entry + idx
            # RATIONALE: Client-side graphid computation uses the same formula as
            # AGE's C code: (label_id << 48) | entry_id. Verified against AGE 1.7.0 source.
            graphid = (label_id << ENTRY_ID_BITS) | entry_id
            props = { object_id: row['new_id'], object_type: object_type }
            props_json = JSON.generate(props).gsub('"', '""')
            copy.put_data("#{graphid},\"#{props_json}\"\n")
            batch_count += 1
          end
        end
        batch_count
      end

      sig do
        params(conn: PG::Connection, graph_name: String, label_name: String, table_name: String,
               object_type: String, batch_size: Integer, progress_key: T.nilable(String)).returns(Integer)
      end
      def load_cypher_merge(conn, graph_name:, label_name:, table_name:, object_type:, batch_size:, progress_key:)
        # Same cursor requirement as :copy_stdin — MERGE is idempotent per row but the
        # batch window only advances via the progress cursor, so nil spins forever.
        Kernel.raise ArgumentError, 'progress_key is required for :cypher_merge — the batch loop cannot advance without a cursor' if progress_key.nil?

        total = T.let(0, Integer)

        Kernel.loop do
          rows = fetch_vertex_batch(conn, table_name:, progress_key:, batch_size: CYPHER_BATCH_LIMIT)
          break if rows.ntuples.zero?

          statements = build_vertex_merge_statements(rows, object_type:)
          execute_cypher_batch(conn, graph_name:, statements:)
          total += rows.ntuples
          track_vertex_progress(conn, progress_key:, rows:, total:, label_name:, batch_count: rows.ntuples)
        end

        total
      rescue PG::Error
        begin
          BulkLoad.query(conn, 'ROLLBACK')
        rescue PG::Error
          nil
        end
        Kernel.raise
      ensure
        begin
          BulkLoad.query(conn, 'SET search_path = "$user", public')
        rescue PG::Error
          nil
        end
      end

      sig { params(conn: PG::Connection, table_name: String, progress_key: T.nilable(String), batch_size: Integer).returns(PG::Result) }
      def fetch_vertex_batch(conn, table_name:, progress_key:, batch_size:)
        last_uuid = progress_key ? ProgressTracker.load_progress(conn, progress_key) : nil
        where = last_uuid ? "AND new_id > '#{escape_uuid(last_uuid)}'" : ''
        BulkLoad.query(conn, "SELECT new_id FROM _migration_pk_map WHERE table_name = '#{table_name}' #{where} ORDER BY new_id LIMIT #{batch_size}")
      end

      sig { params(rows: PG::Result, object_type: String).returns(T::Array[String]) }
      def build_vertex_merge_statements(rows, object_type:)
        # Escape object_type the same as uuid — callers validate against
        # VALID_OBJECT_TYPE upstream, but defense-in-depth against a future
        # caller that skips it (a single quote would break out of the Cypher literal).
        escaped_type = object_type.gsub("'", "''")
        rows.each_with_index.map do |row, idx|
          uuid = T.must(row['new_id']).gsub("'", "''")
          "MERGE (v#{idx} {object_id: '#{uuid}', object_type: '#{escaped_type}'})"
        end
      end

      sig { params(conn: PG::Connection, graph_name: String, statements: T::Array[String]).void }
      def execute_cypher_batch(conn, graph_name:, statements:)
        BulkLoad.query(conn, 'BEGIN')
        BulkLoad.query(conn, "LOAD 'age'")
        BulkLoad.query(conn, 'SET search_path = ag_catalog, "$user", public')
        tag = "age_bulk_#{Process.pid}"
        BulkLoad.query(conn,
                       "SELECT * FROM ag_catalog.cypher('#{graph_name}', $#{tag}$ #{statements.join(' WITH * ')} $#{tag}$) AS (result ag_catalog.agtype)")
        BulkLoad.query(conn, 'COMMIT')
      end

      sig { params(uuid: String).returns(String) }
      def escape_uuid(uuid)
        uuid.gsub("'", "''")
      end
    end

    # --- EdgeLoader: bulk edge creation ---

    module EdgeLoader
      module_function

      # Bundles the stable SQL-state fields forwarded through the insert-select
      # edge-loading chain (load_insert_select → execute_edge_insert_batch →
      # build_edge_insert_select_sql). Constructed once at the entry point so
      # each chain method takes (conn, config, ...) plus only its per-batch
      # locals, instead of re-declaring every field at each layer. Plain class
      # with typed attr_readers — codebase convention for value objects
      # (Sorbet/ForbidTStruct cop gates new T::Struct usage).
      class EdgeConfig
        sig { returns(Integer) }
        attr_reader :label_id

        sig { returns(String) }
        attr_reader :seq_name

        sig { returns(String) }
        attr_reader :qualified

        sig { returns(String) }
        attr_reader :from_type

        sig { returns(String) }
        attr_reader :to_type

        sig { returns(String) }
        attr_reader :props_clause

        sig { returns(String) }
        attr_reader :dblink_conn

        sig { returns(String) }
        attr_reader :join_table

        sig { returns(String) }
        attr_reader :from_col

        sig { returns(String) }
        attr_reader :to_col

        sig { returns(String) }
        attr_reader :from_table

        sig { returns(String) }
        attr_reader :to_table

        sig { returns(T::Array[T::Hash[Symbol, String]]) }
        attr_reader :property_cols

        sig do
          params(label_id: Integer, seq_name: String, qualified: String, from_type: String,
                 to_type: String, props_clause: String, dblink_conn: String, join_table: String,
                 from_col: String, to_col: String, from_table: String, to_table: String,
                 property_cols: T::Array[T::Hash[Symbol, String]]).void
        end
        def initialize(label_id:, seq_name:, qualified:, from_type:, to_type:, props_clause:,
                       dblink_conn:, join_table:, from_col:, to_col:, from_table:, to_table:, property_cols:)
          @label_id = label_id
          @seq_name = seq_name
          @qualified = qualified
          @from_type = from_type
          @to_type = to_type
          @props_clause = props_clause
          @dblink_conn = dblink_conn
          @join_table = join_table
          @from_col = from_col
          @to_col = to_col
          @from_table = from_table
          @to_table = to_table
          @property_cols = property_cols
        end
      end

      # Loads edges from a join table in autosis_old_restore via dblink.
      #
      # Options:
      #   strategy:     :insert_select | :cypher_merge
      #   graph_name:   AGE graph name
      #   edge_label:   edge label name (e.g., 'HAS_NAME')
      #   dblink_conn:  dblink connection string to autosis_old_restore
      #   join_table:   source join table name (e.g., 'person_entity_names')
      #   from_col:     FK column in join table for source entity
      #   to_col:       FK column in join table for target entity
      #   from_table:   _migration_pk_map table_name for source
      #   to_table:     _migration_pk_map table_name for target
      #   from_type:    label name for source vertex type
      #   to_type:      label name for target vertex type
      #   property_cols: array of { col:, prop: } mappings for edge properties
      #   batch_size:   rows per batch
      #   progress_key: key for progress table
      #
      # Requires IdMapping to be built first (call IdMapping.build!).
      #
      # Returns { created:, skipped:, elapsed_seconds: }
      sig do
        params(conn: PG::Connection, strategy: Symbol, graph_name: String, edge_label: String,
               dblink_conn: String, join_table: String, from_col: String, to_col: String,
               from_table: String, to_table: String, from_type: String, to_type: String,
               property_cols: T::Array[T::Hash[Symbol, String]], batch_size: Integer,
               progress_key: T.nilable(String)).returns(T::Hash[Symbol, T.untyped])
      end
      def load(conn, strategy:, graph_name:, edge_label:, dblink_conn:, join_table:, from_col:, to_col:, from_table:, to_table:, from_type:,
               to_type:, property_cols: [], batch_size: DEFAULT_BATCH_SIZE, progress_key: nil)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        total = T.let(0, Integer)
        skipped = T.let(0, Integer)

        case strategy
        when :insert_select
          result_is = load_insert_select(conn, graph_name:, edge_label:, dblink_conn:, join_table:, from_col:, to_col:, from_table:, to_table:,
                                               from_type:, to_type:, property_cols:, batch_size:, progress_key:)
          total = T.must(result_is[0])
          skipped = T.must(result_is[1])
        when :cypher_merge
          result_cm = load_cypher_merge(conn, graph_name:, edge_label:, dblink_conn:, join_table:, from_col:, to_col:, from_table:, to_table:,
                                              from_type:, to_type:, property_cols:, batch_size:, progress_key:)
          total = T.must(result_cm[0])
          skipped = T.must(result_cm[1])
        else
          Kernel.raise ArgumentError, "Unknown strategy: #{strategy}. Note: :copy_stdin not supported for edges — use :insert_select."
        end

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        { created: total, skipped: skipped, elapsed_seconds: elapsed }
      end

      sig do
        params(conn: PG::Connection, graph_name: String, edge_label: String, dblink_conn: String,
               join_table: String, from_col: String, to_col: String, from_table: String,
               to_table: String, from_type: String, to_type: String,
               property_cols: T::Array[T::Hash[Symbol, String]], batch_size: Integer,
               progress_key: T.nilable(String)).returns(T::Array[Integer])
      end
      def load_insert_select(conn, graph_name:, edge_label:, dblink_conn:, join_table:, from_col:, to_col:, from_table:, to_table:, from_type:,
                             to_type:, property_cols:, batch_size:, progress_key:)
        label = GraphAdmin.label_info(conn, edge_label)
        qualified = GraphAdmin.quote_qualified(graph_name, edge_label)
        seq_name = "#{GraphAdmin.quote_ident(graph_name)}.#{GraphAdmin.quote_ident(T.cast(label[:seq_name], String))}"
        prop_pairs = property_cols.map { |pc| "'#{pc[:prop]}', t.#{pc[:col]}::text" }
        props_clause = prop_pairs.empty? ? '' : ", #{prop_pairs.join(', ')}"
        config = EdgeConfig.new(
          label_id: T.cast(label[:id], Integer), seq_name: seq_name, qualified: qualified,
          from_type: from_type, to_type: to_type, props_clause: props_clause,
          dblink_conn: dblink_conn, join_table: join_table, from_col: from_col, to_col: to_col,
          from_table: from_table, to_table: to_table, property_cols: property_cols
        )
        total = T.let(0, Integer)
        skipped = T.let(0, Integer)

        Kernel.loop do
          batch_result = execute_edge_insert_batch(conn, config, batch_size: batch_size, progress_key: progress_key,
                                                                 edge_label: edge_label, total: total, skipped: skipped)
          total = T.cast(batch_result[:total], Integer)
          skipped = T.cast(batch_result[:skipped], Integer)
          break if T.cast(batch_result[:done], T::Boolean)
        end

        [total, skipped]
      end

      sig do
        params(conn: PG::Connection, config: EdgeConfig, batch_size: Integer,
               progress_key: T.nilable(String), edge_label: String, total: Integer,
               skipped: Integer).returns(T::Hash[Symbol, T.untyped])
      end
      def execute_edge_insert_batch(conn, config, batch_size:, progress_key:, edge_label:, total:, skipped:)
        id_where = build_edge_progress_where(conn, progress_key:)
        sql = build_edge_insert_select_sql(config, id_where:, batch_size:)
        inserted = process_edge_insert_batch(conn, sql)
        total += inserted

        done = inserted.zero?
        unless done
          if progress_key
            save_last_edge_id(conn, dblink_conn: config.dblink_conn, join_table: config.join_table, id_where:, progress_key:, total:, skipped:)
          end
          ApacheAge.logger.info("[edges] #{edge_label} (#{config.join_table}): #{total} created, #{skipped} skipped (#{inserted} this batch)")
          done = inserted < batch_size
        end
        { total: total, skipped: skipped, done: done }
      end

      sig { params(conn: PG::Connection, progress_key: T.nilable(String)).returns(String) }
      def build_edge_progress_where(conn, progress_key:)
        last_id = progress_key ? ProgressTracker.load_edge_progress(conn, progress_key) : ''
        last_id.empty? ? '' : "WHERE id > '#{last_id.gsub("'", "''")}'::uuid"
      end

      sig { params(conn: PG::Connection, sql: String).returns(Integer) }
      def process_edge_insert_batch(conn, sql)
        BulkLoad.query(conn, sql).cmd_tuples
      end

      # Renders the three property-column SQL fragments (select list, dblink list, typed cast list)
      # shared by insert-select and fetch edge-row builders.
      sig { params(property_cols: T::Array[T::Hash[Symbol, String]]).returns([String, String, String]) }
      def render_property_cols(property_cols)
        return ['', '', ''] if property_cols.empty?

        [
          property_cols.map { |pc| ", t.#{pc[:col]}" }
                       .join,
          property_cols.map { |pc| ", #{pc[:col]}" }
                       .join,
          property_cols.map { |pc| ", #{pc[:col]} #{pc[:col_type] || 'numeric'}" }
                       .join
        ]
      end

      sig { params(config: EdgeConfig, id_where: String, batch_size: Integer).returns(String) }
      def build_edge_insert_select_sql(config, id_where:, batch_size:)
        # RATIONALE: Single CTE combines dblink read, UUID resolution via _migration_pk_map,
        # and graphid lookup via _age_uuid_graphid temp table. This is a single SQL round-trip
        # per batch — the database does all three joins server-side.
        col_select, col_dblink, col_types = render_property_cols(config.property_cols)
        <<~SQL.squish
          WITH batch AS (
            SELECT t.id, t.#{config.from_col}, t.#{config.to_col}#{col_select},
              fk_from.new_id::text AS from_new_id,
              fk_to.new_id::text   AS to_new_id
            FROM dblink('#{config.dblink_conn}',
              'SELECT id, #{config.from_col}, #{config.to_col}#{col_dblink}
               FROM #{config.join_table} #{id_where}
               ORDER BY id LIMIT #{batch_size}')
              AS t(id uuid, #{config.from_col} uuid, #{config.to_col} uuid#{col_types})
            LEFT JOIN _migration_pk_map fk_from
              ON fk_from.table_name = '#{config.from_table}' AND fk_from.old_id = t.#{config.from_col}::text
            LEFT JOIN _migration_pk_map fk_to
              ON fk_to.table_name = '#{config.to_table}' AND fk_to.old_id = t.#{config.to_col}::text
          )
          INSERT INTO #{config.qualified} (id, start_id, end_id, properties)
          SELECT
            ag_catalog._graphid(#{config.label_id}, nextval('#{config.seq_name}')),
            vg.graphid,
            eg.graphid,
            ag_catalog.agtype_build_map('from_type', '#{config.from_type}', 'to_type', '#{config.to_type}'#{config.props_clause})
          FROM batch
          JOIN _age_uuid_graphid vg ON vg.object_id = batch.from_new_id::uuid
          JOIN _age_uuid_graphid eg ON eg.object_id = batch.to_new_id::uuid
          ORDER BY batch.id
          ON CONFLICT DO NOTHING
        SQL
      end

      sig { params(conn: PG::Connection, dblink_conn: String, join_table: String, id_where: String, progress_key: T.nilable(String), total: Integer, skipped: Integer).void }
      def save_last_edge_id(conn, dblink_conn:, join_table:, id_where:, progress_key:, total:, skipped:)
        last_row = BulkLoad.query(conn,
                                  "SELECT id FROM dblink('#{dblink_conn}',
            'SELECT id FROM #{join_table} #{id_where} ORDER BY id DESC LIMIT 1')
            AS t(id uuid)")
        ProgressTracker.save_edge_progress(conn, T.must(progress_key), T.must(last_row.first['id']), total, skipped) if last_row.ntuples.positive?
      end

      sig do
        params(conn: PG::Connection, graph_name: String, edge_label: String, dblink_conn: String,
               join_table: String, from_col: String, to_col: String, from_table: String,
               to_table: String, from_type: String, to_type: String,
               property_cols: T::Array[T::Hash[Symbol, String]], batch_size: Integer,
               progress_key: T.nilable(String)).returns(T::Array[Integer])
      end
      def load_cypher_merge(conn, graph_name:, edge_label:, dblink_conn:, join_table:, from_col:, to_col:, from_table:, to_table:, from_type:,
                            to_type:, property_cols:, batch_size:, progress_key:)
        total = T.let(0, Integer)
        skipped = T.let(0, Integer)
        cypher_batch = T.let(50, Integer)

        Kernel.loop do
          rows = fetch_next_edge_batch(conn, dblink_conn:, join_table:, from_col:, to_col:, from_table:, to_table:, property_cols:, progress_key:,
                                             batch_size:)
          break if rows.ntuples.zero?

          execute_edge_cypher_batches(conn, graph_name:, edge_label:, rows:, property_cols:, cypher_batch:)
          total += rows.ntuples

          last_row = rows[rows.ntuples - 1]
          ProgressTracker.save_edge_progress(conn, T.must(progress_key), T.must(last_row['id']), total, skipped) if progress_key
          ApacheAge.logger.info("[edges] #{edge_label} (#{join_table}): #{total} created (cypher_merge)")
          break if rows.ntuples < batch_size
        end

        [total, skipped]
      rescue PG::Error
        begin
          BulkLoad.query(conn, 'ROLLBACK')
        rescue PG::Error
          nil
        end
        Kernel.raise
      ensure
        begin
          BulkLoad.query(conn, 'SET search_path = "$user", public')
        rescue PG::Error
          nil
        end
      end

      sig do
        params(conn: PG::Connection, dblink_conn: String, join_table: String, from_col: String,
               to_col: String, from_table: String, to_table: String,
               property_cols: T::Array[T::Hash[Symbol, String]], progress_key: T.nilable(String),
               batch_size: Integer).returns(PG::Result)
      end
      def fetch_next_edge_batch(conn, dblink_conn:, join_table:, from_col:, to_col:, from_table:, to_table:, property_cols:, progress_key:,
                                batch_size:)
        last_id = progress_key ? ProgressTracker.load_edge_progress(conn, progress_key) : ''
        id_where = last_id.empty? ? '' : "WHERE id > '#{last_id.gsub("'", "''")}'::uuid"
        fetch_edge_rows(conn, dblink_conn:, join_table:, from_col:, to_col:, from_table:, to_table:, property_cols:, id_where:, batch_size:)
      end

      sig do
        params(conn: PG::Connection, dblink_conn: String, join_table: String, from_col: String,
               to_col: String, from_table: String, to_table: String,
               property_cols: T::Array[T::Hash[Symbol, String]], id_where: String,
               batch_size: Integer).returns(PG::Result)
      end
      def fetch_edge_rows(conn, dblink_conn:, join_table:, from_col:, to_col:, from_table:, to_table:, property_cols:, id_where:, batch_size:)
        col_select, col_dblink, col_types = render_property_cols(property_cols)
        BulkLoad.query(conn, <<~SQL.squish)
          SELECT t.id, t.#{from_col}, t.#{to_col}#{col_select},
            fk_from.new_id AS from_new_id,
            fk_to.new_id   AS to_new_id
          FROM dblink('#{dblink_conn}',
            'SELECT id, #{from_col}, #{to_col}#{col_dblink}
             FROM #{join_table} #{id_where}
             ORDER BY id LIMIT #{batch_size}')
            AS t(id uuid, #{from_col} uuid, #{to_col} uuid#{col_types})
          LEFT JOIN _migration_pk_map fk_from
            ON fk_from.table_name = '#{from_table}' AND fk_from.old_id = t.#{from_col}::text
          LEFT JOIN _migration_pk_map fk_to
            ON fk_to.table_name = '#{to_table}' AND fk_to.old_id = t.#{to_col}::text
          WHERE fk_from.new_id IS NOT NULL AND fk_to.new_id IS NOT NULL
          ORDER BY t.id
        SQL
      end

      sig { params(conn: PG::Connection, graph_name: String, edge_label: String, rows: PG::Result, property_cols: T::Array[T::Hash[Symbol, String]], cypher_batch: Integer).void }
      def execute_edge_cypher_batches(conn, graph_name:, edge_label:, rows:, property_cols:, cypher_batch:)
        rows.each_slice(cypher_batch) do |slice|
          statements = build_edge_cypher_statements(slice, edge_label:, property_cols:)
          BulkLoad.query(conn, 'BEGIN')
          BulkLoad.query(conn, "LOAD 'age'")
          BulkLoad.query(conn, 'SET search_path = ag_catalog, "$user", public')
          tag = "age_edge_#{Process.pid}"
          BulkLoad.query(conn,
                         "SELECT * FROM ag_catalog.cypher('#{graph_name}', $#{tag}$ #{statements.join(' WITH * ')} $#{tag}$) AS (result ag_catalog.agtype)")
          BulkLoad.query(conn, 'COMMIT')
        end
      end

      sig { params(slice: T::Array[T::Hash[String, String]], edge_label: String, property_cols: T::Array[T::Hash[Symbol, String]]).returns(T::Array[String]) }
      def build_edge_cypher_statements(slice, edge_label:, property_cols:)
        slice.each_with_index.map do |row, idx|
          from = T.must(row['from_new_id']).gsub("'", "''")
          to = T.must(row['to_new_id']).gsub("'", "''")
          props = property_cols.map { |pc| "e.#{pc[:prop]} = #{cypher_literal(T.must(row[T.must(pc[:col]).to_s]))}" }
                               .join(', ')
          set_clause = props.empty? ? '' : " SET #{props}"
          "MATCH (a#{idx} {object_id: '#{from}'}), (b#{idx} {object_id: '#{to}'}) MERGE (a#{idx})-[e#{idx}:#{edge_label}]->(b#{idx})#{set_clause}"
        end
      end

      sig { params(value: String).returns(String) }
      def cypher_literal(value)
        if value.match?(/\A-?\d+(\.\d+)?\z/)
          value
        else
          "'#{value.gsub("'", "''")}'"
        end
      end
    end

    # --- IdMapping: UUID to graphid resolution ---

    module IdMapping
      module_function

      # Builds a temp table mapping every vertex's object_id (UUID) to its AGE graphid.
      # Must be called after all vertices are loaded, before edge creation.
      # The table _age_uuid_graphid is created in the current session's temp schema.
      #
      # RATIONALE: agtype does not support the ->> operator directly. Must cast via
      # text → json →> key. This is a known AGE limitation (AGE 1.7.0).
      # Would need: AGE adding native agtype ->> text operator to reconsider.
      sig { params(conn: PG::Connection, graph_name: String).returns(Integer) }
      def build!(conn, graph_name)
        BulkLoad.query(conn, <<~SQL.squish)
          CREATE TEMP TABLE IF NOT EXISTS _age_uuid_graphid (
            object_id uuid PRIMARY KEY,
            graphid bigint NOT NULL
          )
        SQL

        all_labels = GraphAdmin.labels(conn)
        vertex_labels = all_labels.reject { |l| T.cast(l[:kind], String) != 'v' || T.cast(l[:name], String).start_with?('_ag_label_') }

        count = T.let(0, Integer)
        vertex_labels.each do |lbl|
          qualified = GraphAdmin.quote_qualified(graph_name, T.cast(lbl[:name], String))
          BulkLoad.query(conn, <<~SQL.squish)
            INSERT INTO _age_uuid_graphid (object_id, graphid)
            SELECT
              (properties::text::json->>'object_id')::uuid,
              id
            FROM #{qualified}
            ON CONFLICT DO NOTHING
          SQL
          count = BulkLoad.parse_int(BulkLoad.query(conn, 'SELECT count(*) FROM _age_uuid_graphid').first['count'], 10)
          ApacheAge.logger.info("[id_map] After #{T.cast(lbl[:name], String)}: #{count} total mappings")
        end

        count
      end

      sig { params(conn: PG::Connection, object_ids: T::Array[String]).returns(T::Hash[String, Integer]) }
      def resolve_batch(conn, object_ids)
        return {} if object_ids.empty?

        placeholders = object_ids.each_with_index.map { |_, i| "$#{i + 1}" }
                                                 .join(', ')
        rows = BulkLoad.query(conn, "SELECT object_id, graphid FROM _age_uuid_graphid WHERE object_id IN (#{placeholders})", object_ids)
        result = {}
        rows.each { |r| result[r['object_id']] = BulkLoad.parse_int(r['graphid'], 10) }
        result
      end

      sig { params(conn: PG::Connection, object_id: String).returns(T.nilable(Integer)) }
      def resolve(conn, object_id)
        row = BulkLoad.query(conn, 'SELECT graphid FROM _age_uuid_graphid WHERE object_id = $1', [object_id])
        return nil if row.ntuples.zero?

        BulkLoad.parse_int(row.first['graphid'], 10)
      end

      sig { params(conn: PG::Connection).void }
      def cleanup!(conn)
        BulkLoad.query(conn, 'DROP TABLE IF EXISTS _age_uuid_graphid')
      end

      sig { params(conn: PG::Connection).returns(T::Boolean) }
      def built?(conn)
        BulkLoad.parse_int(BulkLoad.query(conn, 'SELECT count(*) FROM _age_uuid_graphid').first['count'], 10).positive?
      rescue PG::Error
        false
      end
    end

    # --- ProgressTracker: resumability ---

    module ProgressTracker
      module_function

      sig { params(conn: PG::Connection).void }
      def ensure_vertex_table!(conn)
        BulkLoad.query(conn, <<~SQL.squish)
          CREATE TABLE IF NOT EXISTS _age_vertex_migration_progress (
            label_name text PRIMARY KEY,
            last_object_id text NOT NULL DEFAULT '',
            vertices_created bigint NOT NULL DEFAULT 0,
            updated_at timestamp NOT NULL DEFAULT now()
          )
        SQL
      end

      sig { params(conn: PG::Connection).void }
      def ensure_edge_table!(conn)
        BulkLoad.query(conn, <<~SQL.squish)
          CREATE TABLE IF NOT EXISTS _age_edge_migration_progress (
            join_table text PRIMARY KEY,
            last_source_id text NOT NULL DEFAULT '',
            edges_created bigint NOT NULL DEFAULT 0,
            skipped_null_fk bigint NOT NULL DEFAULT 0,
            updated_at timestamp NOT NULL DEFAULT now()
          )
        SQL
      end

      sig { params(conn: PG::Connection, label_name: String).returns(T.nilable(String)) }
      def load_progress(conn, label_name)
        row = BulkLoad.query(conn, 'SELECT last_object_id FROM _age_vertex_migration_progress WHERE label_name = $1', [label_name])
        return nil if row.ntuples.zero?

        val = row.first['last_object_id']
        return nil if val.nil?
        return nil if val.empty?

        val
      end

      # RATIONALE: conn.exec_params returns T.untyped from PG gem RBI — void method, return value ignored.
      sig { params(conn: PG::Connection, label_name: String, last_object_id: String, count: Integer).returns(T.untyped) }
      def save_progress(conn, label_name, last_object_id, count)
        conn.exec_params(
          <<~SQL.squish,
            INSERT INTO _age_vertex_migration_progress (label_name, last_object_id, vertices_created, updated_at)
            VALUES ($1, $2, $3, now())
            ON CONFLICT (label_name) DO UPDATE SET
              last_object_id = EXCLUDED.last_object_id,
              vertices_created = EXCLUDED.vertices_created,
              updated_at = EXCLUDED.updated_at
          SQL
          [label_name, last_object_id, count]
        )
      end

      sig { params(conn: PG::Connection, join_table: String).returns(String) }
      def load_edge_progress(conn, join_table)
        row = BulkLoad.query(conn, 'SELECT last_source_id FROM _age_edge_migration_progress WHERE join_table = $1', [join_table])
        return '' if row.ntuples.zero?

        T.must(row.first['last_source_id'])
      end

      # RATIONALE: conn.exec_params returns T.untyped from PG gem RBI — void method, return value ignored.
      sig { params(conn: PG::Connection, join_table: String, last_source_id: String, edges_created: Integer, skipped: Integer).returns(T.untyped) }
      def save_edge_progress(conn, join_table, last_source_id, edges_created, skipped)
        conn.exec_params(
          <<~SQL.squish,
            INSERT INTO _age_edge_migration_progress (join_table, last_source_id, edges_created, skipped_null_fk, updated_at)
            VALUES ($1, $2, $3, $4, now())
            ON CONFLICT (join_table) DO UPDATE SET
              last_source_id = EXCLUDED.last_source_id,
              edges_created = EXCLUDED.edges_created,
              skipped_null_fk = EXCLUDED.skipped_null_fk,
              updated_at = EXCLUDED.updated_at
          SQL
          [join_table, last_source_id, edges_created, skipped]
        )
      end
    end
  end
end
