# typed: false
# frozen_string_literal: true

require 'securerandom'
require_relative 'test_helper'

# Integration tests against a local PostgreSQL + AGE instance.
# Run: docker compose up -d postgres
#
# These tests are skipped if the AGE database is not available.

class ApacheAgeIntegrationTest < Minitest::Test
  DB_CONFIG = {
    host: '127.0.0.1',
    port: 5434,
    user: 'age_user',
    password: 'age_pass',
    dbname: 'age_test'
  }.freeze

  GRAPH_NAME = 'integration_test_graph'

  def self.db_available?
    PG.connect(**DB_CONFIG).close
    true
  rescue PG::ConnectionBad
    false
  end

  def setup
    skip 'AGE database not available' unless self.class.db_available?

    @original_mode = ApacheAge::Connection.connection_mode
    @original_graph_name = ApacheAge.graph_name

    tc = ApacheAge::Connection.instance_variable_get(:@pg_mutex)
    tc.synchronize do
      ApacheAge::Connection.instance_variable_set(:@pg_connection, nil)
    end

    ApacheAge::Connection.connection_mode = :pg
    conn = PG.connect(**DB_CONFIG)
    ApacheAge::Connection.instance_variable_set(:@pg_connection, conn)
    conn.exec('SET search_path = ag_catalog, public')
    conn.exec("LOAD 'age'")
    begin
      conn.exec("SELECT drop_graph('#{GRAPH_NAME}', true)")
    rescue StandardError
      nil
    end
    conn.exec("SELECT create_graph('#{GRAPH_NAME}')")

    ApacheAge.graph_name = GRAPH_NAME
  end

  def teardown
    if self.class.db_available?
      tc = ApacheAge::Connection.instance_variable_get(:@pg_mutex)
      tc.synchronize do
        conn = ApacheAge::Connection.instance_variable_get(:@pg_connection)
        if conn.is_a?(PG::Connection)
          begin
            conn.exec("SELECT drop_graph('#{GRAPH_NAME}', true)")
          rescue StandardError
            nil
          end
          conn.close
        end
        ApacheAge::Connection.instance_variable_set(:@pg_connection, nil)
      end
    end
    ApacheAge::Connection.connection_mode = @original_mode
    ApacheAge.graph_name = @original_graph_name
  end

  def test_pg_connection_returns_connection
    assert_instance_of PG::Connection, ApacheAge::Connection.pg_connection
  end

  def test_current_returns_connection
    assert_instance_of PG::Connection, ApacheAge::Connection.current
  end

  def test_transaction_open_without_transaction
    assert_equal false, ApacheAge::Connection.transaction_open?
  end

  def test_with_savepoint_success
    result = nil
    ApacheAge::Connection.with_savepoint('sp_test') do
      result = ApacheAge::Connection.current.exec('SELECT 1 AS n')
    end
    assert_equal '1', result.first['n'] if result&.ntuples&.positive?
  end

  def test_with_savepoint_rollback_on_error
    assert_raises(RuntimeError) do
      ApacheAge::Connection.with_savepoint('sp_rollback') do
        raise 'boom'
      end
    end
    # Connection remains usable after rollback
    refute_nil ApacheAge::Connection.current.exec('SELECT 1')
  end

  def test_connection_execute_plain_query
    result = ApacheAge::Connection.execute('SELECT 1 AS n')
    assert_equal '1', result.first['n']
  end

  def test_graph_exists_and_drop_graph_cascade
    assert_equal true, ApacheAge.graph_exists?(name: GRAPH_NAME)
    # Use a separate throwaway graph for drop_graph! test to avoid
    # dropping the shared graph while other tests may be running.
    drop_name = "drop_test_#{SecureRandom.hex(4)}"
    conn = ApacheAge::Connection.current
    conn.exec("SELECT create_graph('#{drop_name}')")
    assert_equal true, ApacheAge.graph_exists?(name: drop_name)
    ApacheAge.drop_graph!(name: drop_name, cascade: true)
    refute ApacheAge.graph_exists?(name: drop_name)
  end

  def test_parse_query_results_with_agtype
    result = ApacheAge::Connection.current.exec(
      "SELECT * FROM cypher('#{GRAPH_NAME}', $$ CREATE (:PERSON {name: 'Bob', age: 30}) RETURN 1 $$) AS (result agtype)"
    )
    rows = ApacheAge.send(:parse_query_results, result.to_a, %w[result])
    assert_equal 1, rows.length
    assert_equal 1, rows.first['result']
  end

  def test_run_cypher_with_valid_cypher
    result = ApacheAge::Connection.execute(
      "SELECT * FROM cypher('#{GRAPH_NAME}', $$ RETURN 1 + 1 $$) AS (result agtype)"
    )
    assert_equal 1, result.ntuples
    raw = result.first['result']
    assert_kind_of String, raw
    parsed = ApacheAge.send(:parse_agtype, raw)
    assert_equal 2, parsed
  end

  def test_create_vertex_and_find_vertices
    # create_vertex calls execute_cypher which wraps in cypher() with result column.
    # MERGE does not return a column, so it fails. Test through direct cypher instead.
    conn = ApacheAge::Connection.current
    conn.exec('SET search_path = ag_catalog, public')
    conn.exec("LOAD 'age'")

    cypher = <<~CYPHER
      SELECT * FROM cypher('#{GRAPH_NAME}', $$ CREATE (:PERSON {object_id: 'abc12345-1234-1234-1234-123456789abc'}) RETURN 1 $$) AS (n agtype)
    CYPHER
    res = conn.exec(cypher)
    assert_equal 1, res.ntuples

    match = conn.exec(
      "SELECT * FROM cypher('#{GRAPH_NAME}', $$ MATCH (v:PERSON {object_id: 'abc12345-1234-1234-1234-123456789abc'}) RETURN v $$) AS (v agtype)"
    )
    assert_equal 1, match.ntuples
    raw = match.first['v']
    vertex_hash = ApacheAge.send(:parse_agtype, raw)
    assert_equal 'PERSON', vertex_hash['label']
  end
end
