# typed: strong
# frozen_string_literal: true

require 'logger'
require 'bigdecimal'

module ApacheAge
  class GraphLifecycleError < StandardError; end
  class CypherExecutionError < StandardError; end

  # Regex matching Python and Node.js driver validation:
  #   - Starts with letter or underscore
  #   - May contain letters, digits, underscores, dots, hyphens
  #   - Must end with letter, digit, or underscore
  #   - 3–63 characters (PostgreSQL identifier limit)
  VALID_GRAPH_NAME = /\A[A-Za-z_][A-Za-z0-9_.-]*[A-Za-z0-9_]\z|\A[A-Za-z_]\z/
  MIN_GRAPH_NAME_LENGTH = 3
  MAX_GRAPH_NAME_LENGTH = 63

  # Label names are stricter — only letters, digits, underscores (no dots/hyphens).
  VALID_LABEL_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  # Column name and type validation — prevents SQL injection in AS clause.
  VALID_COLUMN_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
  VALID_COLUMN_TYPE = /\A[A-Za-z_][A-Za-z0-9_.]*\z/

  class << self
    extend T::Sig

    sig { returns(T.nilable(String)) }
    attr_reader :graph_name

    sig { returns(Logger) }
    def logger
      @logger || Logger.new($stderr)
    end

    # --- Configuration ---

    sig { params(name: String).void }
    def graph_name=(name)
      @graph_name = name
    end

    sig { params(conn: T.any(PG::Connection, T.untyped)).void }
    def connection=(conn)
      Connection.set_pg_connection(conn)
    end

    sig { returns(T.untyped) }
    def connection
      Connection.current
    end

    sig { params(logger: Logger).void }
    def logger=(logger)
      @logger = logger
    end

    # --- Session setup ---

    # Prepare a PG connection for AGE usage. Equivalent to Python's
    # setUpAge / configure_connection and Node.js's setAGETypes.
    #
    # Loads the AGE extension into the session, sets search_path to
    # include ag_catalog, and returns true on success.
    #
    # Optionally creates the AGE extension if it doesn't exist
    # (requires superuser privileges).
    sig { params(conn: T.any(PG::Connection, T.untyped), create_extension: T::Boolean).returns(T.untyped) }
    def setup_connection(conn = nil, create_extension: false)
      target = conn || Connection.current

      if create_extension
        target.exec('CREATE EXTENSION IF NOT EXISTS age')
      end

      target.exec("LOAD 'age'")
      target.exec('SET search_path = ag_catalog, "$user", public')

      true
    end

    # --- Graph lifecycle ---

    # Create a new graph. Idempotent — raises GraphLifecycleError if the
    # graph already exists (matching Python/Node.js behavior).
    sig { params(graph_name: String).void }
    def create_graph(graph_name:)
      validate_graph_name!(graph_name)
      sql = "SELECT ag_catalog.create_graph('#{cypher_escape(graph_name)}')"
      Connection.execute(sql)
    rescue StandardError => e
      raise GraphLifecycleError, "Failed to create graph '#{graph_name}': #{e.message}"
    end

    # Drop an existing graph.
    sig { params(graph_name: String, cascade: T::Boolean).void }
    def drop_graph(graph_name:, cascade: false)
      validate_graph_name!(graph_name)
      sql = "SELECT ag_catalog.drop_graph('#{cypher_escape(graph_name)}', #{cascade})"
      Connection.execute(sql)
    rescue StandardError => e
      raise GraphLifecycleError, "Failed to drop graph '#{graph_name}': #{e.message}"
    end

    # Check whether a graph exists.
    sig { params(graph_name: String).returns(T::Boolean) }
    def graph_exists?(graph_name:)
      validate_graph_name!(graph_name)
      result = Connection.execute(
        "SELECT count(*) FROM ag_catalog.ag_graph WHERE name = '#{cypher_escape(graph_name)}'"
      )
      count = result.first&.values&.first&.to_i || 0
      count.positive?
    end

    # --- Query execution ---

    # Execute a Cypher query against an AGE graph and return parsed results.
    #
    # @param graph_name [String] The target graph (defaults to module-level config)
    # @param cypher [String] The Cypher query string
    # @param columns [Array<String>, String] Column definitions for the result set.
    #   Array of column names (types default to agtype) or a full column
    #   definition string like "v ag_catalog.agtype, e ag_catalog.agtype"
    # @param params [Hash, nil] Cypher parameters. When provided, uses
    #   age_prepare_cypher for safe parameterized execution.
    # @return [Array<Hash<String, Object>>] Parsed result rows
    #
    # @example Simple query
    #   ApacheAge.query_cypher('my_graph', 'MATCH (n) RETURN n', columns: ['n'])
    #
    # @example With parameters
    #   ApacheAge.query_cypher('my_graph',
    #     'MATCH (n:Person {name: $name}) RETURN n',
    #     columns: ['n'],
    #     params: { name: 'Alice' }
    #   )
    sig do
      params(
        graph_name: String,
        cypher: String,
        columns: T.any(String, T::Array[String]),
        params: T.nilable(T::Hash[Symbol, T.untyped])
      ).returns(T::Array[T::Hash[String, T.untyped]])
    end
    def query_cypher(graph_name, cypher, columns:, params: nil)
      validate_graph_name!(graph_name)

      col_def = if columns.is_a?(String)
                  validate_column_def!(columns)
                  columns
                else
                  columns.each { |c| validate_column_name!(c) }
                  columns.map { |c| "#{c} ag_catalog.agtype" }.join(', ')
                end

      col_names = columns.is_a?(String) ? columns.split(',').map { |c| c.strip.split.first } : columns

      if params && !params.empty?
        results = execute_prepared_cypher(graph_name, cypher, col_def, params)
      else
        dq = dollar_quote(cypher)
        sql = "SELECT * FROM ag_catalog.cypher('#{cypher_escape(graph_name)}', #{dq}#{cypher}#{dq}) AS (#{col_def})"
        results = Connection.execute(sql)
      end

      parse_query_results(results, col_names)
    end

    # --- Agtype parsing ---

    # Parse a single agtype value. Public API for users who need to
    # decode raw agtype strings returned by other means.
    sig { params(value: T.nilable(String)).returns(T.untyped) }
    def parse_agtype(value)
      return nil if value.nil?
      return nil if value.strip.empty?

      AgtypeParser.parse(value)
    rescue AgtypeParser::ParseError => e
      logger.warn("age_graph.agtype_parse_failed value=#{value&.slice(0, 100)} error=#{e.message}")
      nil
    end

    # --- Utility ---

    # Escape a value for safe interpolation into a Cypher string literal.
    # Public utility — users constructing Cypher strings need this.
    # Uses PostgreSQL's single-quote doubling convention.
    sig { params(value: String).returns(String) }
    def cypher_escape(value)
      value.gsub("'", "''")
    end

    # Encode a Ruby value as an agtype literal string.
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
      when String then "\"#{value.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}\""
      when Symbol then agtype_encode(value.to_s)
      when Array then "[#{value.map { |v| agtype_encode(v) }.join(', ')}]"
      when Hash
        pairs = value.map { |k, v| "\"#{k}\": #{agtype_encode(v)}" }.join(', ')
        "{#{pairs}}"
      else
        "\"#{value}\""
      end
    end

    private

    # Execute a Cypher query using age_prepare_cypher for parameterized execution.
    # This is the safe path for user-supplied Cypher parameters.
    #
    # Flow (matching Go driver):
    #   1. age_prepare_cypher(graph_name, cypher) — sets session-scoped state
    #   2. cypher(NULL, NULL, param1, param2, ...) — executes using prepared state
    sig do
      params(
        graph_name: String,
        cypher: String,
        columns_def: String,
        params: T::Hash[Symbol, T.untyped]
      ).returns(T.untyped)
    end
    def execute_prepared_cypher(graph_name, cypher, columns_def, params)
      conn = Connection.current
      raw_conn = if conn.respond_to?(:raw_connection)
                   conn.raw_connection
                 else
                   conn
                 end
      pg_conn = T.cast(raw_conn, PG::Connection)

      # Step 1: Prepare the Cypher statement (session-scoped).
      pg_conn.exec_params(
        "SELECT * FROM ag_catalog.age_prepare_cypher($1, $2)",
        [graph_name, cypher]
      )

      # Step 2: Execute using the prepared statement.
      param_values = params.values.map { |v| agtype_encode(v) }
      params_clause = param_values.empty? ? '' : ", #{param_values.map { |v| "'#{v}'" }.join(', ')}"
      exec_sql = "SELECT * FROM ag_catalog.cypher(NULL, NULL#{params_clause}) AS (#{columns_def})"
      Connection.execute(exec_sql)
    end

    # Parse PG result rows into an array of hashes with typed Ruby values.
    sig { params(results: T.untyped, col_names: T::Array[String]).returns(T::Array[T::Hash[String, T.untyped]]) }
    def parse_query_results(results, col_names)
      rows = []
      results.each do |row|
        parsed = {}
        col_names.each_with_index do |name, idx|
          raw = row.is_a?(Array) ? row[idx] : row[name] || row[name.to_sym]
          parsed[name] = parse_agtype(raw)
        end
        rows << parsed
      end
      rows
    end

    # Deterministic dollar-quoting matching the Node.js driver approach:
    # use $$ when the Cypher string doesn't contain $$, otherwise find
    # a unique $tag$ delimiter.
    sig { params(cypher: String).returns(String) }
    def dollar_quote(cypher)
      return '$$' unless cypher.include?('$$')

      tag = 'age'
      tag = "age_#{Kernel.rand(1_000_000)}" while cypher.include?("$#{tag}$")
      "$tag$"
    end

    # --- Validation ---

    sig { params(name: String).void }
    def validate_graph_name!(name)
      raise ArgumentError, "Invalid AGE graph name '#{name}'" unless name.match?(VALID_GRAPH_NAME)
      raise ArgumentError, "AGE graph name must be at least #{MIN_GRAPH_NAME_LENGTH} characters" if name.length < MIN_GRAPH_NAME_LENGTH
      raise ArgumentError, "AGE graph name must not exceed #{MAX_GRAPH_NAME_LENGTH} characters (PostgreSQL name limit)" if name.length > MAX_GRAPH_NAME_LENGTH
    end

    sig { params(name: String).void }
    def validate_label_name!(name)
      raise ArgumentError, "Invalid AGE label name '#{name}'" unless name.match?(VALID_LABEL_NAME)
      raise ArgumentError, "AGE label name must not exceed #{MAX_GRAPH_NAME_LENGTH} characters" if name.length > MAX_GRAPH_NAME_LENGTH
    end

    sig { params(name: String).void }
    def validate_column_name!(name)
      raise ArgumentError, "Invalid column name '#{name}'" unless name.match?(VALID_COLUMN_NAME)
    end

    sig { params(col_def: String).void }
    def validate_column_def!(col_def)
      col_def.split(',').each do |part|
        parts = part.strip.split
        raise ArgumentError, "Invalid column definition '#{part.strip}'" if parts.length < 2
        name = T.must(parts[0])
        type = T.must(parts[1])
        raise ArgumentError, "Invalid column name '#{name}'" unless name.match?(VALID_COLUMN_NAME)
        raise ArgumentError, "Invalid column type '#{type}'" unless type.match?(VALID_COLUMN_TYPE)
      end
    end

    private :validate_graph_name!, :validate_label_name!, :validate_column_name!, :validate_column_def!,
            :dollar_quote, :parse_query_results, :execute_prepared_cypher

    # Initialize logger to stderr by default; Railtie overrides for Rails apps.
    @logger = Logger.new($stderr)
    @graph_name = nil
  end
end
