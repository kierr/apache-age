# typed: strict
# frozen_string_literal: true

require 'bigdecimal'
require 'logger'
require 'pg'
require 'sorbet-runtime'

# Apache AGE graph client for Ruby. Works with or without Rails.
#
# == Rails (auto-detected)
#   ApacheAge.graph_name = 'my_graph'
#   # logger is auto-configured by Railtie when SemanticLogger is present
#   require 'apache_age/bulk_load'  # opt-in
#
# == Standalone (no Rails)
#   ApacheAge.connection = PG::Connection.new(host: 'localhost', dbname: 'mydb')
#   ApacheAge.graph_name = 'my_graph'
#
module ApacheAge
  class EdgeCreationError < StandardError; end
  class GraphLifecycleError < StandardError; end
  class CypherExecutionError < StandardError; end

  VALID_LABEL = /\A[A-Z][A-Z0-9_]*\z/
  VALID_PROPERTY_KEY = /\A[a-z_][a-z0-9_]*\z/
  VALID_OBJECT_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  VALID_OBJECT_TYPE = /\A[a-z_][a-z0-9_]*\z/
  # Matches Python driver's VALID_GRAPH_NAME but enforces PostgreSQL's
  # 63-byte identifier limit. AGE graph names are PostgreSQL identifiers.
  # RATIONALE: Regex enforces 3+ char minimum directly — the old single-char
  # alternation was dead code since MIN_GRAPH_NAME_LENGTH=3 rejected 1-char names.
  # Would need MIN_GRAPH_NAME_LENGTH < 3 to reconsider.
  VALID_GRAPH_NAME = /\A[A-Za-z_][A-Za-z0-9_]{2,}\z/
  MIN_GRAPH_NAME_LENGTH = 3
  MAX_GRAPH_NAME_LENGTH = 63
  # Column/type identifier validation — prevents SQL injection in AS clause.
  VALID_COLUMN_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
  VALID_COLUMN_TYPE = /\A[A-Za-z_][A-Za-z0-9_.]*\z/
  NEGATIVE_CACHE_TTL = 30
  MAX_DOLLAR_QUOTE_ATTEMPTS = 100

  @graph_name = T.let('apache_age', String)
  @logger = T.let(Logger.new($stdout), ::Logger)
  @pg_connection = T.let(nil, T.nilable(PG::Connection))
  @pg_mutex = T.let(Mutex.new, Mutex)

  class << self
    extend T::Sig

    sig { returns(String) }
    attr_accessor :graph_name

    sig { returns(::Logger) }
    attr_accessor :logger

    # RATIONALE: @pg_connection is protected by @pg_mutex for thread safety.
    # PG::Connection is not thread-safe for concurrent queries; the mutex
    # serializes all access. For high-concurrency workloads, use ActiveRecord
    # (which provides a connection pool) instead.
    sig { params(conn: T.nilable(PG::Connection)).void }
    def connection=(conn)
      @pg_mutex.synchronize { @pg_connection = T.let(conn, T.nilable(PG::Connection)) }
    end

    sig { returns(T.nilable(PG::Connection)) }
    def connection
      @pg_mutex.synchronize { @pg_connection }
    end

    # Set up the AGE extension on a connection and register it for subsequent queries.
    # This is the primary entry point for standalone (non-ActiveRecord) usage.
    #
    # When +conn+ is provided, it is registered as the shared PG connection
    # (equivalent to calling +ApacheAge.connection = conn+ first) so that
    # subsequent +create_graph!+, +query_cypher+, etc. use this connection.
    #
    # WARNING: +create_extension: true+ executes CREATE EXTENSION IF NOT EXISTS age,
    # which is a superuser-only DDL operation. For non-superuser roles, use
    # +create_extension: false+ and ensure the extension is pre-installed.
    sig { params(conn: T.nilable(PG::Connection), create_extension: T::Boolean).void }
    def setup_connection(conn = nil, create_extension: true)
      pg_conn = conn || @pg_connection
      raise ArgumentError, 'No PG::Connection available — pass conn: or set ApacheAge.connection first' unless pg_conn

      # Register the connection so subsequent queries find it
      self.connection = pg_conn if conn

      begin
        if create_extension
          log(:info, 'age_graph.setup_connection', message: 'Installing AGE extension (requires superuser)')
          pg_conn.exec('CREATE EXTENSION IF NOT EXISTS age')
        end
        pg_conn.exec("LOAD 'age'")
        pg_conn.exec('SET search_path = ag_catalog, "$user", public')
      rescue StandardError => e
        # Attempt to restore search_path on failure so the connection isn't
        # left in a half-configured state
        begin
          pg_conn.exec('SET search_path = "$user", public')
        rescue StandardError
          nil
        end
        raise GraphLifecycleError, "Failed to set up AGE connection: #{e.message}"
      end
      log(:info, 'age_graph.setup_connection', message: 'AGE extension loaded and search_path set')
    end

    # Structured logging dispatch: preserves keyword args for SemanticLogger,
    # falls back to string interpolation for stdlib Logger.
    sig { params(level: Symbol, message: String, kwargs: T.untyped).void }
    def log(level, message, **kwargs)
      if kwargs.any?
        logger.public_send(level, message, **kwargs)
      else
        logger.public_send(level, message)
      end
    rescue ArgumentError
      # RATIONALE: Rescue ArgumentError because stdlib Logger#info does not accept
      # keyword arguments. The fallback formats kwargs as key=value pairs.
      logger.public_send(level, "#{message} (#{kwargs.map { |k, v| "#{k}=#{v}" }.join(', ')})")
    end

    # --- Graph Lifecycle API ---
    # Matches the Go, Python, and Node.js drivers' graph management capabilities.

    # Create a graph. Raises GraphLifecycleError on failure.
    # Non-idempotent — raises on duplicate graph name.
    sig { params(name: T.nilable(String)).void }
    def create_graph!(name: nil)
      graph = name || graph_name
      validate_graph_name!(graph)
      ensure_age_session

      # Idempotent: just call create_graph and ignore duplicate-errors.
      # Avoids TOCTOU race between graph_exists? and create_graph.
      Connection.execute("SELECT ag_catalog.create_graph('#{cypher_escape(graph)}')")
      reset_graph_availability!
      log(:info, 'age_graph.created', graph_name: graph)
    rescue StandardError => e
      raise GraphLifecycleError, "Failed to create graph '#{graph}': #{e.message}"
    end

    # Drop a graph. Raises GraphLifecycleError on failure.
    # RATIONALE: cascade: true is an irreversible destructive operation.
    # Log a warning so operators can audit cascade usage.
    # Returns silently if the graph does not exist.
    sig { params(name: T.nilable(String), cascade: T::Boolean).void }
    def drop_graph!(name: nil, cascade: false)
      graph = name || graph_name
      validate_graph_name!(graph)
      ensure_age_session

      if cascade
        log(:warn, 'age_graph.drop_cascade', graph_name: graph,
                                             message: 'CASCADE drop will destroy all labels and data in this graph')
      end
      Connection.execute("SELECT ag_catalog.drop_graph('#{cypher_escape(graph)}', #{cascade})")
      reset_graph_availability!
      log(:info, 'age_graph.dropped', graph_name: graph, cascade: cascade)
    rescue StandardError => e
      raise GraphLifecycleError, "Failed to drop graph '#{graph}': #{e.message}"
    end

    # Check whether a specific graph exists. Does not use the negative cache.
    sig { params(name: T.nilable(String)).returns(T::Boolean) }
    def graph_exists?(name: nil)
      graph = name || graph_name
      ensure_age_session
      cypher = "SELECT count(*) FROM ag_catalog.ag_graph WHERE name = '#{cypher_escape(graph)}'"
      result = Connection.execute(cypher)
      if result.is_a?(PG::Result)
        T.cast(result.first, T::Hash[String, T.untyped])['count'].to_s.to_i.positive?
      else
        T.unsafe(result).first&.fetch('count', 0).to_i.positive?
      end
    rescue StandardError
      false
    end

    # --- Generic Cypher Execution API ---
    # Matches the execCypher/queryCypher methods in the Go, Python, JDBC,
    # and Node.js drivers. Supports arbitrary Cypher with typed column
    # definitions, returning parsed Vertex/Edge/Path/primitive results.

    # Execute an arbitrary Cypher query with column definitions.
    #
    # columns: either a String like "v ag_catalog.agtype, e ag_catalog.agtype"
    #          or an Array of column name Strings (typed as agtype automatically).
    # params:  optional Hash of bind parameters for age_prepare_cypher
    #          (server-side parameterized execution). Keys are Cypher parameter
    #          names (without $), values are the parameter values.
    #
    # Returns an Array of Hashes, with agtype values parsed into
    # Vertex/Edge/Path/primitive Ruby types via AgtypeParser.
    #
    # Example:
    #   ApacheAge.query_cypher("MATCH (v:Person) RETURN v LIMIT 10", columns: ["v"])
    #   ApacheAge.query_cypher("MATCH (v)-[e:KNOWS]->(w) RETURN v, e, w", columns: %w[v e w])
    #   ApacheAge.query_cypher("MATCH (n) WHERE n.name = $name RETURN n", columns: ["n"], params: { name: "Alice" })
    sig do
      params(
        cypher: String,
        columns: T.any(String, T::Array[String]),
        params: T.nilable(T::Hash[String, T.untyped])
      ).returns(T::Array[T::Hash[String, T.untyped]])
    end
    def query_cypher(cypher, columns:, params: nil)
      return [] unless graph_available?

      col_def = if columns.is_a?(String)
                  validate_column_def!(columns)
                  columns
                else
                  columns.each { |c| validate_column_name!(c) }
                  columns.map { |c| "#{c} ag_catalog.agtype" }.join(', ')
                end
      col_names = columns.is_a?(String) ? columns.split(',').map { |c| c.strip.split.first } : columns

      validate_graph_name!(graph_name) unless graph_name.match?(VALID_GRAPH_NAME)

      if params && !params.empty?
        raw_result = execute_prepared_cypher(cypher, col_def, params)
      else
        delimiter = dollar_quote(cypher)
        sql = <<~SQL
          SELECT ag_catalog.cypher('#{cypher_escape(graph_name)}',
            #{delimiter} #{cypher} #{delimiter}) AS (#{col_def})
        SQL
        start_ts = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raw_result = Connection.execute(sql)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_ts
        row_count = raw_result.is_a?(PG::Result) ? raw_result.ntuples : T.unsafe(raw_result).length
        log(:info, 'age_graph.query_cypher', graph_name: graph_name,
                                             query_snippet: cypher[0, 80], elapsed_ms: (elapsed * 1000).round(1), row_count: row_count)
      end

      rows = if raw_result.is_a?(PG::Result)
               raw_result.map { |row| row }
             else
               T.unsafe(raw_result).to_a
             end

      parse_query_results(rows, T.cast(col_names, T::Array[String]))
    rescue StandardError => e
      log(:error, 'age_graph.query_cypher_failed', error_class: e.class.name, error_message: e.message)
      raise CypherExecutionError, "Cypher execution failed: #{e.message}"
    end

    # Execute arbitrary Cypher using age_prepare_cypher with server-side
    # parameterized bindings. This is the safest execution path — values
    # are bound server-side, never interpolated into the Cypher string.
    #
    # Matches the Go driver's ExecCypher and Python driver's execCypher
    # parameterized execution paths.
    #
    # Example:
    #   ApacheAge.execute_prepared_cypher(
    #     "MATCH (v:Person {name: $name}) RETURN v",
    #     "v ag_catalog.agtype",
    #     { "name" => "Alice" }
    #   )
    sig do
      params(
        cypher: String,
        columns_def: String,
        params: T::Hash[String, T.untyped]
      ).returns(T.untyped)
    end
    def execute_prepared_cypher(cypher, columns_def, params)
      ensure_age_session
      validate_graph_name!(graph_name) unless graph_name.match?(VALID_GRAPH_NAME)

      # Use the same connection for both prepare and execute to avoid
      # a race where AR pool checkouts differ between steps.
      conn = Connection.current
      raw_conn = if conn.respond_to?(:raw_connection)
                   conn.raw_connection
                 else
                   conn
                 end
      pg_conn = T.cast(raw_conn, PG::Connection)

      # Prepare the Cypher statement on the server.
      # age_prepare_cypher sets session-scoped state: the graph name and
      # Cypher string are bound via SQL parameters ($1, $2), preventing
      # SQL-level injection. After this call, cypher(NULL, NULL) uses
      # the prepared statement.
      prepare_sql = 'SELECT * FROM ag_catalog.age_prepare_cypher($1, $2)'
      pg_conn.exec_params(prepare_sql, [graph_name, cypher])

      # Encode Cypher parameters as agtype literals.
      # Single quotes in values are escaped (doubled) to prevent SQL
      # injection through the string-literal boundary.
      param_values = params.values.map do |v|
        encoded = agtype_encode(v)
        "'#{encoded.gsub("'", "''")}'"
      end
      params_clause = param_values.empty? ? '' : ", #{param_values.join(', ')}"

      # Execute using session-scoped prepared state.
      # cypher(NULL, NULL) reads the graph + cypher from age_prepare_cypher.
      exec_sql = "SELECT * FROM ag_catalog.cypher(NULL, NULL#{params_clause}) AS (#{columns_def})"
      start_ts = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raw_result = pg_conn.exec(exec_sql)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_ts
      row_count = raw_result.is_a?(PG::Result) ? raw_result.ntuples : 0
      log(:info, 'age_graph.prepared_cypher', graph_name: graph_name,
                                              query_snippet: cypher[0, 80], elapsed_ms: (elapsed * 1000).round(1),
                                              row_count: row_count, param_count: params.size)
      raw_result
    rescue StandardError => e
      log(:error, 'age_graph.prepared_cypher_failed', error_class: e.class.name, error_message: e.message)
      raise CypherExecutionError, "Prepared Cypher execution failed: #{e.message}"
    end

    # --- Core CRUD API ---

    sig { params(object_id: String, object_type: String).returns(T::Boolean) }
    def create_vertex(object_id:, object_type:)
      return false unless graph_available?

      validate_object_id!(object_id)
      validate_object_type!(object_type)

      # RATIONALE: Vertices are labeled by object_type so MERGE finds them by
      # {object_id, object_type}. The edge builder (build_edge_cypher) uses
      # the same label via the object_type property stored on each vertex.
      cypher = <<~CYPHER
        MERGE (v:#{object_type} {object_id: '#{cypher_escape(object_id)}'})
      CYPHER
      execute_cypher(cypher)
      true
    rescue StandardError => e
      log(:error, 'age_graph.create_vertex_failed', error_class: e.class.name, error_message: e.message,
                                                    backtrace: e.backtrace&.first(5))
      false
    end

    sig do
      params(
        from_object_id: String, to_object_id: String,
        label: String, properties: T::Hash[Symbol, T.untyped]
      ).returns(T::Boolean)
    end
    def create_edge(from_object_id, to_object_id, label, properties: {})
      return false unless graph_available?

      validate_label!(label)
      cypher = build_edge_cypher(from_object_id, to_object_id, label, properties)
      execute_cypher(cypher)
      true
    rescue EdgeCreationError => e
      log(:warn, 'age_graph.edge_creation_failed', error_class: e.class.name, error_message: e.message)
      false
    rescue StandardError => e
      log(:error, 'age_graph.create_edge_failed', error_class: e.class.name, error_message: e.message,
                                                  backtrace: e.backtrace&.first(5))
      false
    end

    sig { params(object_id: String, edge_label: String, direction: Symbol).returns(T::Array[TraverseResult]) }
    def traverse(object_id, edge_label, direction: :outgoing)
      return [] unless graph_available?

      validate_label!(edge_label)
      cypher = build_traverse_cypher([object_id], edge_label, direction)
      result = execute_cypher(cypher)
      parse_traverse_results(result)
    rescue StandardError => e
      log(:error, 'age_graph.traverse_failed', error_class: e.class.name, error_message: e.message)
      []
    end

    sig { params(object_ids: T::Array[String], edge_label: String, direction: Symbol).returns(T::Array[TraverseResult]) }
    def traverse_batch(object_ids, edge_label, direction: :outgoing)
      return [] unless graph_available?
      return [] if object_ids.empty?

      validate_label!(edge_label)
      object_ids.each_slice(500).flat_map do |batch|
        cypher = build_traverse_cypher(batch, edge_label, direction)
        result = execute_cypher(cypher)
        parse_traverse_results(result)
      end
    rescue StandardError => e
      log(:error, 'age_graph.traverse_batch_failed', error_class: e.class.name, error_message: e.message)
      []
    end

    sig { params(target_object_ids: T::Array[String], edge_label: String).returns(T::Array[ReverseTraverseResult]) }
    def reverse_traverse_batch(target_object_ids, edge_label)
      return [] unless graph_available?
      return [] if target_object_ids.empty?

      validate_label!(edge_label)
      target_object_ids.each_slice(500).flat_map do |batch|
        cypher = <<~CYPHER
          MATCH (source)-[e:#{edge_label}]->(target)
          WHERE target.object_id IN [#{batch.map { |id| "'#{cypher_escape(id)}'" }.join(', ')}]
          RETURN source.object_id AS source_object_id,
                 target.object_id AS target_object_id,
                 source.object_type AS source_object_type
        CYPHER
        result = execute_cypher_with_columns(cypher)
        parse_reverse_traverse_results(result)
      end
    rescue StandardError => e
      log(:error, 'age_graph.reverse_traverse_batch_failed', error_class: e.class.name, error_message: e.message)
      []
    end

    sig { params(object_id: String, edge_label: String, direction: Symbol).returns(T::Array[EdgeTraverseResult]) }
    def traverse_edges(object_id, edge_label, direction: :outgoing)
      return [] unless graph_available?

      validate_label!(edge_label)
      cypher = build_traverse_edges_cypher(object_id, edge_label, direction)
      result = execute_cypher_with_columns(cypher)
      parse_edge_traverse_results(result)
    rescue StandardError => e
      log(:error, 'age_graph.traverse_edges_failed', error_class: e.class.name, error_message: e.message)
      []
    end

    sig { params(source_object_ids: T::Array[String], edge_label: String).returns(T::Array[ForwardTraverseResult]) }
    def forward_traverse_batch(source_object_ids, edge_label)
      return [] unless graph_available?
      return [] if source_object_ids.empty?

      validate_label!(edge_label)
      source_object_ids.each_slice(500).flat_map do |batch|
        cypher = <<~CYPHER
          MATCH (source)-[e:#{edge_label}]->(target)
          WHERE source.object_id IN [#{batch.map { |id| "'#{cypher_escape(id)}'" }.join(', ')}]
          RETURN source.object_id AS source_object_id,
                 target.object_id AS target_object_id,
                 target.object_type AS target_object_type
        CYPHER
        result = execute_cypher_with_columns(cypher)
        parse_forward_traverse_results(result)
      end
    rescue StandardError => e
      log(:error, 'age_graph.forward_traverse_batch_failed', error_class: e.class.name, error_message: e.message)
      []
    end

    sig { params(object_id: T.nilable(T.any(String, Integer))).returns(T::Boolean) }
    def vertex_exists?(object_id:)
      return false if object_id.nil?

      oid = validate_object_id!(object_id)
      return false unless graph_available?

      cypher = "MATCH (v {object_id: '#{cypher_escape(oid)}'}) RETURN count(v) AS cnt"
      result = execute_cypher(cypher)
      row = T.cast(result, T::Array[T::Hash[String, T.untyped]]).first
      cnt = parse_agtype_numeric(row&.fetch('result', row.fetch('cnt', nil)))
      cnt ? cnt.to_i.positive? : false
    rescue StandardError
      false
    end

    sig { params(from_object_id: String, to_object_id: String, label: String).returns(T::Boolean) }
    def edge_exists?(from_object_id, to_object_id, label)
      return false unless graph_available?

      validate_label!(label)
      cypher = "MATCH (a {object_id: '#{cypher_escape(from_object_id)}'})-[e:#{label}]->(b {object_id: '#{cypher_escape(to_object_id)}'}) RETURN count(e) AS cnt"
      result = execute_cypher(cypher)
      row = T.cast(result, T::Array[T::Hash[String, T.untyped]]).first
      cnt = parse_agtype_numeric(row&.fetch('result', row.fetch('cnt', nil)))
      cnt ? cnt.to_i.positive? : false
    rescue StandardError
      false
    end

    sig { params(object_id: T.any(String, Integer)).returns(T::Boolean) }
    def delete_vertex(object_id)
      return false unless graph_available?

      oid = validate_object_id!(object_id)
      cypher = "MATCH (v {object_id: '#{cypher_escape(oid)}'}) DELETE v"
      execute_cypher(cypher)
      true
    rescue StandardError => e
      log(:error, 'age_graph.delete_vertex_failed', error_class: e.class.name, error_message: e.message)
      false
    end

    sig { params(from_object_id: String, to_object_id: String, label: String).returns(T::Boolean) }
    def delete_edge(from_object_id, to_object_id, label)
      return false unless graph_available?

      validate_label!(label)
      cypher = "MATCH (a {object_id: '#{cypher_escape(from_object_id)}'})-[e:#{label}]->(b {object_id: '#{cypher_escape(to_object_id)}'}) DELETE e"
      execute_cypher(cypher)
      true
    rescue StandardError => e
      log(:error, 'age_graph.delete_edge_failed', error_class: e.class.name, error_message: e.message)
      false
    end

    sig { void }
    def reset_graph_availability!
      @graph_available = T.let(nil, T.nilable(T::Boolean))
      @graph_available_checked_at = T.let(nil, T.nilable(Time))
    end

    sig { params(block: T.proc.returns(T.untyped)).returns(T.untyped) }
    def with_age_session(&)
      ensure_age_session
      yield
    end

    sig { params(identity: String, block: T.proc.returns(T.untyped)).returns(T::Boolean) }
    def with_savepoint(identity, &)
      ApacheAge::Connection.with_savepoint(identity, &)
    rescue EdgeCreationError
      false
    rescue ArgumentError
      raise
    rescue StandardError
      false
    end

    sig { void }
    def ensure_age_session
      conn = ApacheAge::Connection.current
      conn_id = ApacheAge::Connection.backend_pid
      load_age_if_needed(conn, conn_id)
    end

    sig { params(value: String).returns(String) }
    def cypher_escape(value)
      value.gsub("'", "''")
    end

    # RATIONALE: graph_name is validated at query time, not at the setter,
    # because the setter is used during initialization (Railtie config) when
    # the graph may not exist yet. Validation at query time catches injection
    # without breaking the init workflow.
    sig { returns(T::Boolean) }
    def graph_available?
      return false if @graph_name.empty?
      return false unless @graph_name.match?(VALID_GRAPH_NAME)

      if @graph_available.nil? || (@graph_available == false && @graph_available_checked_at && Time.now - @graph_available_checked_at > NEGATIVE_CACHE_TTL)
        @graph_available_checked_at = Time.now
        @graph_available = check_graph_exists?
      end
      @graph_available
    end

    # --- Agtype parsing ---

    # Parse an agtype value string into its Ruby representation.
    # Uses the full AgtypeParser for complete type support.
    #
    # Handles: strings, integers, floats, booleans, null, arrays, objects,
    # ::vertex, ::edge, ::path, ::numeric, NaN, Infinity, -Infinity,
    # escaped strings, nested structures.
    # RATIONALE: parse_agtype raises on malformed input by default. The
    # lenient: true option returns nil for parse failures, preserving the
    # old behavior for callers that expect it.
    sig { params(value: T.nilable(String), lenient: T::Boolean).returns(T.untyped) }
    def parse_agtype(value, lenient: false)
      return nil if value.nil?
      return nil if value.strip.empty?

      AgtypeParser.parse(value)
    rescue AgtypeParser::ParseError => e
      raise unless lenient

      log(:warn, 'age_graph.agtype_parse_failed', value: T.must(value)[0..80], error: e.message)
      nil
    end

    # Parse an agtype numeric value. Supports ::numeric (BigDecimal),
    # NaN, Infinity, -Infinity, regular floats, and integers.
    # Raises ArgumentError for nil input; returns nil for empty strings.
    sig { params(value: T.nilable(String)).returns(T.nilable(Numeric)) }
    def parse_agtype_numeric(value)
      raise ArgumentError, 'Cannot parse nil as agtype numeric' if value.nil?
      return nil if value.strip.empty?

      parsed = AgtypeParser.parse(value.strip)
      return nil if parsed.nil?
      return parsed if parsed.is_a?(Numeric)

      nil
    rescue AgtypeParser::ParseError
      nil
    end

    # Encode a Ruby value as an agtype literal string for parameter binding.
    # RATIONALE: Control-character escaping, hash-key escaping, and the else-branch
    # all apply the same gsub chain as the String branch to ensure valid agtype
    # output that round-trips through AgtypeParser.
    sig { params(value: T.untyped).returns(String) }
    def agtype_encode(value)
      case value
      when nil then 'null'
      when TrueClass then 'true'
      when FalseClass then 'false'
      when Integer then value.to_s
      when Float
        if value.nan?
          'NaN'
        elsif value.infinite?
          value.positive? ? 'Infinity' : '-Infinity'
        else
          value.to_s
        end
      when BigDecimal then "#{value.to_s('F')}::numeric"
      when String then "\"#{escape_agtype_string(value)}\""
      when Symbol then agtype_encode(value.to_s)
      when Array then "[#{value.map { |v| agtype_encode(v) }.join(', ')}]"
      when Hash
        pairs = value.map { |k, v| "\"#{escape_agtype_string(k.to_s)}\": #{agtype_encode(v)}" }.join(', ')
        "{#{pairs}}"
      when Vertex then value.to_agtype
      when Edge then value.to_agtype
      when Path then value.to_agtype
      else
        # RATIONALE: For unsupported types, raise TypeError rather than producing
        # invalid agtype via the old "\"#{value}\"" fallthrough. Callers must
        # explicitly convert custom objects to a supported type.
        raise TypeError, "Cannot encode #{value.class} as agtype: #{value.inspect[0, 100]}"
      end
    end

    # Escape a string for safe embedding in agtype double-quoted literals.
    # Handles: backslash, double-quote, and control characters (\n, \r, \t, \b, \f).
    sig { params(s: String).returns(String) }
    def escape_agtype_string(s)
      s.gsub('\\', '\\\\\\\\')
       .gsub('"', '\\"')
       .gsub("\n", '\\n')
       .gsub("\r", '\\r')
       .gsub("\t", '\\t')
       .gsub("\b", '\\b')
       .gsub("\f", '\\f')
    end

    # --- Private methods ---

    sig { params(label: String).void }
    def validate_label!(label)
      return if label.match?(VALID_LABEL)

      Kernel.raise ArgumentError, "Invalid AGE label '#{label}'"
    end

    # RATIONALE: validate_label_name! has no callers today. Labels are created
    # server-side and validated by AGE. Keeping the constant and method for
    # future label-management API use.
    VALID_LABEL_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    sig { params(name: String).void }
    def validate_label_name!(name)
      Kernel.raise ArgumentError, "Invalid AGE label name '#{name}'" unless name.match?(VALID_LABEL_NAME)
    end

    sig { params(name: String).void }
    def validate_graph_name!(name)
      Kernel.raise ArgumentError, "Invalid AGE graph name '#{name}'" unless name.match?(VALID_GRAPH_NAME)
      if name.length > MAX_GRAPH_NAME_LENGTH
        Kernel.raise ArgumentError,
                     "AGE graph name exceeds #{MAX_GRAPH_NAME_LENGTH} characters"
      end
      return unless name.length < MIN_GRAPH_NAME_LENGTH

      Kernel.raise ArgumentError,
                   "AGE graph name too short (min #{MIN_GRAPH_NAME_LENGTH} chars)"
    end

    sig { params(object_id: T.untyped).returns(String) }
    def validate_object_id!(object_id)
      id = object_id.to_s
      return id if id.match?(VALID_OBJECT_ID)

      Kernel.raise ArgumentError, "Invalid AGE object_id '#{id}'"
    end

    sig { params(object_type: T.untyped).returns(String) }
    def validate_object_type!(object_type)
      type = object_type.to_s
      return type if type.match?(VALID_OBJECT_TYPE)

      Kernel.raise ArgumentError, "Invalid AGE object_type '#{type}'"
    end

    # Validate a single column name to prevent SQL injection in the AS clause.
    sig { params(name: String).void }
    def validate_column_name!(name)
      Kernel.raise ArgumentError, "Invalid column name '#{name}'" unless name.match?(VALID_COLUMN_NAME)
    end

    # Validate a full column definition string like "v ag_catalog.agtype, e ag_catalog.agtype".
    sig { params(col_def: String).void }
    def validate_column_def!(col_def)
      col_def.split(',').each do |part|
        parts = part.strip.split
        Kernel.raise ArgumentError, "Invalid column definition '#{part.strip}'" if parts.length < 2
        name = T.must(parts[0])
        type = T.must(parts[1])
        Kernel.raise ArgumentError, "Invalid column name '#{name}'" unless name.match?(VALID_COLUMN_NAME)
        Kernel.raise ArgumentError, "Invalid column type '#{type}'" unless type.match?(VALID_COLUMN_TYPE)
      end
    end

    sig do
      params(
        from_id: String, to_id: String, label: String,
        properties: T::Hash[Symbol, T.untyped]
      ).returns(String)
    end
    def build_edge_cypher(from_id, to_id, label, properties)
      props_clause = build_properties_clause(properties)
      # RATIONALE: Uses generic 'Entity' label for vertex MERGE so edges can
      # connect vertices of any object_type. The original code used dollar_tag
      # (random per-call label) which was broken — vertices with different
      # random labels could never be found by MERGE. Would need from_type/to_type
      # parameters to use typed labels matching create_vertex's object_type label.
      <<~CYPHER
        MERGE (a:Entity {object_id: '#{cypher_escape(from_id)}'})
        MERGE (b:Entity {object_id: '#{cypher_escape(to_id)}'})
        MERGE (a)-[e:#{label}#{props_clause}]->(b)
      CYPHER
    end

    sig { params(object_ids: T::Array[String], edge_label: String, direction: Symbol).returns(String) }
    def build_traverse_cypher(object_ids, edge_label, direction)
      dir_match = case direction
                  when :outgoing then '-[e:%s]->'
                  when :incoming then '<-[e:%s]-'
                  else '-[e:%s]-'
                  end
      if object_ids.length == 1
        <<~CYPHER
          MATCH (source {object_id: '#{cypher_escape(T.must(object_ids.first))}'})#{format(dir_match, edge_label)}(target)
          RETURN target.object_id AS object_id, target.object_type AS object_type
        CYPHER
      else
        <<~CYPHER
          MATCH (source)-#{format(dir_match, edge_label)}(target)
          WHERE source.object_id IN [#{object_ids.map { |id| "'#{cypher_escape(id)}'" }.join(', ')}]
          RETURN target.object_id AS object_id, target.object_type AS object_type
        CYPHER
      end
    end

    sig { params(object_id: String, edge_label: String, direction: Symbol).returns(String) }
    def build_traverse_edges_cypher(object_id, edge_label, direction)
      dir_match = case direction
                  when :outgoing then '-[e:%s]->'
                  when :incoming then '<-[e:%s]-'
                  else '-[e:%s]-'
                  end
      <<~CYPHER
        MATCH (source {object_id: '#{cypher_escape(object_id)}'})#{format(dir_match, edge_label)}(target)
        RETURN target.object_id AS object_id,
               target.object_type AS object_type,
               e.confidence AS confidence,
               e.first_seen AS first_seen,
               e.last_seen AS last_seen
      CYPHER
    end

    sig { returns(String) }
    def traverse_edges_columns
      'object_id, object_type, confidence, first_seen, last_seen'
    end

    sig { params(properties: T::Hash[Symbol, T.untyped]).returns(String) }
    def build_properties_clause(properties)
      return '' if properties.empty?

      parts = properties.filter_map do |key, value|
        next if value.nil?

        Kernel.raise ArgumentError, "Invalid property key '#{key}'" unless key.to_s.match?(VALID_PROPERTY_KEY)
        unless value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(TrueClass) || value.is_a?(FalseClass)
          Kernel.raise ArgumentError,
                       "Unsupported property value type '#{value.class}'"
        end

        val = case value
              when String then "'#{cypher_escape(value)}'"
              when TrueClass, FalseClass then value.to_s
              else value.to_f == value.to_i ? value.to_i.to_s : value.to_f.to_s
              end
        "#{key}: #{val}"
      end
      " {#{parts.join(', ')}}"
    end

    sig { params(cypher_body: String).returns(T.untyped) }
    def execute_cypher(cypher_body)
      run_cypher(cypher_body, columns: 'result ag_catalog.agtype')
    end

    sig { params(cypher_body: String).returns(T.untyped) }
    def execute_cypher_with_columns(cypher_body)
      run_cypher(cypher_body, columns: traverse_edges_columns)
    end

    sig { params(cypher_body: String, columns: String).returns(T.untyped) }
    def run_cypher(cypher_body, columns:)
      validate_graph_name!(graph_name) unless graph_name.match?(VALID_GRAPH_NAME)
      delimiter = dollar_quote(cypher_body)
      sql = <<~SQL
        SELECT ag_catalog.cypher('#{cypher_escape(graph_name)}',
          #{delimiter} #{cypher_body} #{delimiter}) AS (#{columns})
      SQL
      start_ts = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raw_result = ApacheAge::Connection.execute(sql)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_ts
      row_count = raw_result.is_a?(PG::Result) ? raw_result.ntuples : T.unsafe(raw_result).length
      log(:info, 'age_graph.run_cypher', graph_name: graph_name,
                                         query_snippet: cypher_body[0, 80], elapsed_ms: (elapsed * 1000).round(1), row_count: row_count)
      if raw_result.is_a?(PG::Result)
        raw_result.map { |row| row }
      else
        # ActiveRecord::Result
        T.unsafe(raw_result).to_a
      end
    end

    # Deterministic dollar-quoting matching the Node.js driver approach:
    # use $$ when the Cypher string doesn't contain $$, otherwise find
    # Returns a dollar-quoted string delimiter that does not appear in the
    # given cypher string. For simple queries without $$, returns $$.
    # For queries containing $$, generates a unique tag (e.g. $age_42$) not
    # present in the cypher string, with an iteration limit to prevent
    # pathological cases.
    sig { params(cypher: String).returns(String) }
    def dollar_quote(cypher)
      return '$$' unless cypher.include?('$$')

      attempts = 0
      tag = "age_#{Kernel.rand(1_000_000)}"
      while cypher.include?("$#{tag}$")
        attempts += 1
        if attempts >= MAX_DOLLAR_QUOTE_ATTEMPTS
          raise CypherExecutionError,
                "Could not find unique dollar-quote delimiter after #{MAX_DOLLAR_QUOTE_ATTEMPTS} attempts"
        end

        tag = "age_#{Kernel.rand(1_000_000)}"
      end
      "$#{tag}$"
    end

    # Parse query_cypher results: each row is a Hash, each agtype column
    # value is parsed through the full AgtypeParser into Vertex/Edge/Path/primitives.
    sig { params(rows: T::Array[T.untyped], col_names: T::Array[String]).returns(T::Array[T::Hash[String, T.untyped]]) }
    def parse_query_results(rows, col_names)
      # RATIONALE: Row type is invariant across the result set (PG::Result
      # always returns Hash, AR always returns Hash). Hoist the type check
      # outside the row loop to avoid redundant is_a? per row.
      row_is_hash = rows.first.is_a?(Hash)
      rows.map do |row|
        hash = row_is_hash ? T.cast(row, T::Hash[String, T.untyped]) : T.cast(row, T::Hash[String, T.untyped])
        parsed = {}
        col_names.each do |col|
          # Use fetch with fallback to symbol key — avoids || which silently
          # replaces boolean false with the symbol-keyed lookup result.
          raw = hash.fetch(col) { T.unsafe(hash)[col.to_sym] }
          parsed[col] = raw.nil? ? nil : parse_agtype(raw, lenient: true)
        end
        parsed
      end
    end

    sig { params(result: T.untyped).returns(T::Array[EdgeTraverseResult]) }
    def parse_edge_traverse_results(result)
      rows = T.cast(result, T::Array[T.untyped])
      rows.map do |row|
        hash = row.is_a?(Hash) ? row : T.cast(row, T::Hash[String, T.untyped])
        EdgeTraverseResult.new(
          entity_id: parse_agtype(hash['object_id']).to_s,
          object_type: parse_agtype(hash['object_type']).to_s,
          properties: EdgeProperties.new(
            confidence: parse_agtype_numeric(hash['confidence']),
            first_seen: parse_agtype(hash['first_seen']),
            last_seen: parse_agtype(hash['last_seen'])
          )
        )
      end
    end

    sig { params(result: T.untyped).returns(T::Array[TraverseResult]) }
    def parse_traverse_results(result)
      rows = T.cast(result, T::Array[T.untyped])
      rows.map do |row|
        hash = row.is_a?(Hash) ? row : T.cast(row, T::Hash[String, T.untyped])
        TraverseResult.new(
          entity_id: parse_agtype(hash['object_id']).to_s,
          object_type: parse_agtype(hash['object_type']).to_s
        )
      end
    end

    sig { params(result: T.untyped).returns(T::Array[ForwardTraverseResult]) }
    def parse_forward_traverse_results(result)
      rows = T.cast(result, T::Array[T.untyped])
      rows.map do |row|
        hash = row.is_a?(Hash) ? row : T.cast(row, T::Hash[String, T.untyped])
        ForwardTraverseResult.new(
          source_object_id: parse_agtype(hash['source_object_id']).to_s,
          target_object_id: parse_agtype(hash['target_object_id']).to_s,
          target_object_type: parse_agtype(hash['target_object_type']).to_s
        )
      end
    end

    sig { params(result: T.untyped).returns(T::Array[ReverseTraverseResult]) }
    def parse_reverse_traverse_results(result)
      rows = T.cast(result, T::Array[T.untyped])
      rows.map do |row|
        hash = row.is_a?(Hash) ? row : T.cast(row, T::Hash[String, T.untyped])
        ReverseTraverseResult.new(
          source_object_id: parse_agtype(hash['source_object_id']).to_s,
          target_object_id: parse_agtype(hash['target_object_id']).to_s,
          source_object_type: parse_agtype(hash['source_object_type']).to_s
        )
      end
    end

    sig { returns(Mutex) }
    def mutex
      @mutex ||= T.let(Mutex.new, T.nilable(Mutex))
      @mutex
    end

    sig { params(conn_id: Integer).void }
    def evict_age_loaded_connection(conn_id)
      mutex.synchronize do
        @age_loaded_connections ||= T.let(Set.new, T.nilable(T::Set[Integer]))
        @age_loaded_connections.delete(conn_id)
      end
    end

    sig { params(conn: T.untyped, conn_id: Integer).void }
    def load_age_if_needed(conn, conn_id)
      mutex.synchronize do
        @age_loaded_connections ||= T.let(Set.new, T.nilable(T::Set[Integer]))
        return if @age_loaded_connections.include?(conn_id)

        raw = if conn.respond_to?(:raw_connection)
                conn.raw_connection
              else
                conn
              end
        T.cast(raw, PG::Connection).exec("LOAD 'age'")
        T.cast(raw, PG::Connection).exec('SET search_path = ag_catalog, "$user", public')
        @age_loaded_connections.add(conn_id)
      end
    rescue StandardError => e
      log(:warn, 'age_graph.load_age_failed', error_class: e.class.name, error_message: e.message)
    end

    private :validate_label!, :validate_graph_name!, :validate_object_id!, :validate_object_type!,
            :validate_column_name!, :validate_column_def!, :validate_label_name!,
            :build_edge_cypher, :build_traverse_cypher, :build_traverse_edges_cypher,
            :traverse_edges_columns, :execute_cypher, :execute_cypher_with_columns,
            :dollar_quote, :parse_query_results, :parse_edge_traverse_results, :parse_traverse_results,
            :parse_forward_traverse_results, :parse_reverse_traverse_results,
            :build_properties_clause,
            :escape_agtype_string, :run_cypher, :load_age_if_needed

    sig { returns(T::Boolean) }
    def check_graph_exists?
      cypher = "SELECT count(*) FROM ag_catalog.ag_graph WHERE name = '#{graph_name}'"
      result = ApacheAge::Connection.execute(cypher)
      if result.is_a?(PG::Result)
        T.cast(result.first, T::Hash[String, T.untyped])['count'].to_s.to_i.positive?
      else
        T.unsafe(result).first&.fetch('count', 0).to_i.positive?
      end
    rescue StandardError
      false
    end
    private :check_graph_exists?
  end
end

# Defaults
ApacheAge.graph_name = 'apache_age'
ApacheAge.logger = Logger.new($stdout)

require 'apache_age/agtype_parser'
require 'apache_age/type_base'
require 'apache_age/connection'
require 'apache_age/edge_properties'
require 'apache_age/vertex'
require 'apache_age/edge'
require 'apache_age/path'
require 'apache_age/traverse_result'
require 'apache_age/edge_traverse_result'
require 'apache_age/forward_traverse_result'
require 'apache_age/reverse_traverse_result'

# Railtie auto-loads when AR is present
require 'apache_age/railtie' if defined?(ActiveRecord::Base)
