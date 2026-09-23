# typed: false
# frozen_string_literal: true

require 'securerandom'
require_relative 'test_helper'

# CRUD integration tests against real PostgreSQL + AGE.
# These exercise the graph manipulation API paths in apache-age.rb
# now that the Cypher column bugs are fixed.

class ApacheAgeCrudIntegrationTest < Minitest::Test
  DB_CONFIG = {
    host: '127.0.0.1',
    port: 5434,
    user: 'age_user',
    password: 'age_pass',
    dbname: 'age_test'
  }.freeze

  GRAPH = 'crud_test_graph'

  def self.db_available?
    PG.connect(**DB_CONFIG).close
    true
  rescue PG::ConnectionBad
    false
  end

  def setup
    skip 'AGE database not available' unless self.class.db_available?

    @original_mode = ApacheAge::Connection.connection_mode
    @original_graph = ApacheAge.graph_name

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
      conn.exec("SELECT drop_graph('#{GRAPH}', true)")
    rescue StandardError
      PG::Error
    end
    conn.exec("SELECT create_graph('#{GRAPH}')")
    ApacheAge.graph_name = GRAPH
    ApacheAge.remove_instance_variable(:@graph_available) if ApacheAge.instance_variable_defined?(:@graph_available)
  end

  def teardown
    if self.class.db_available?
      tc = ApacheAge::Connection.instance_variable_get(:@pg_mutex)
      tc.synchronize do
        conn = ApacheAge::Connection.instance_variable_get(:@pg_connection)
        if conn.is_a?(PG::Connection)
          begin
            conn.exec("SELECT drop_graph('#{GRAPH}', true)")
          rescue StandardError
            PG::Error
          end
          conn.close
        end
        ApacheAge::Connection.instance_variable_set(:@pg_connection, nil)
      end
    end
    ApacheAge::Connection.connection_mode = @original_mode
    ApacheAge.graph_name = @original_graph
    ApacheAge.remove_instance_variable(:@graph_available) if ApacheAge.instance_variable_defined?(:@graph_available)
  end

  # -- query_cypher --

  def test_query_cypher_raw
    # query_cypher wraps in execute_cypher which adds AS(result ag_catalog.agtype)
    # AGE 1.7.0 has an issue where CREATE + RETURN in the same cypher statement
    # inside a SELECT * FROM cypher(...) wrapper fails. Test with simple RETURN.
    rows = ApacheAge.query_cypher(
      'RETURN 1',
      columns: 'result ag_catalog.agtype'
    )
    assert_equal 1, rows.length
  end

  def test_query_cypher_array_columns
    rows = ApacheAge.query_cypher(
      'RETURN 2',
      columns: %w[result]
    )
    assert_equal 1, rows.length
    assert_equal({ 'result' => 2 }, rows.first)
  end

  def test_query_cypher_with_params_raises
    # Prepared cypher params don't work with AGE 1.7.0 (cypher(NULL,NULL,...))
    assert_raises(ApacheAge::CypherExecutionError) do
      ApacheAge.query_cypher(
        'CREATE (:PERSON {name: $name}) RETURN 1',
        columns: 'result ag_catalog.agtype',
        params: { 'name' => 'Bob' }
      )
    end
  end

  def test_query_cypher_when_graph_unavailable_returns_empty
    ApacheAge.instance_variable_set(:@graph_available, false)
    rows = ApacheAge.query_cypher('RETURN 1', columns: 'result ag_catalog.agtype')
    assert_equal [], rows
  end

  def test_query_cypher_invalid_column_raises
    # Invalid column raises ArgumentError from build_column_definition, which is
    # caught in query_cypher and wrapped as CypherExecutionError.
    assert_raises(ApacheAge::CypherExecutionError) do
      ApacheAge.query_cypher('RETURN 1', columns: 'invalid_no_type')
    end
  end

  # -- create_* --

  def test_create_vertex
    # VALID_OBJECT_TYPE requires lowercase. AGE labels are case-insensitive on
    # create but stored as uppercase; the library uses lowercase for validation.
    result = ApacheAge.send(:create_vertex, object_id: new_uuid, object_type: 'person')
    assert_equal true, result
  end

  def test_create_edge
    # NOTE: create_edge uses MERGE (a:Entity ...) not the source vertex label
    # so vertices must exist beforehand or MERGE creates them
    v1 = new_uuid
    v2 = new_uuid
    # Pre-create vertices
    ApacheAge.send(:create_vertex, object_id: v1, object_type: 'PERSON')
    ApacheAge.send(:create_vertex, object_id: v2, object_type: 'PERSON')
    result = ApacheAge.send(:create_edge, v1, v2, 'KNOWS')
    assert_equal true, result
  end

  # -- traverse --

  def test_traverse_outgoing_empty
    assert_equal [], ApacheAge.send(:traverse, new_uuid, 'KNOWS', direction: :outgoing)
  end

  def test_traverse_incoming_empty
    assert_equal [], ApacheAge.send(:traverse, new_uuid, 'KNOWS', direction: :incoming)
  end

  def test_traverse_both_empty
    assert_equal [], ApacheAge.send(:traverse, new_uuid, 'KNOWS', direction: :both)
  end

  def test_traverse_batch_empty
    assert_equal [], ApacheAge.send(:traverse_batch, [new_uuid], 'KNOWS')
  end

  def test_reverse_traverse_batch_empty
    assert_equal [], ApacheAge.send(:reverse_traverse_batch, [new_uuid], 'KNOWS')
  end

  def test_traverse_edges_empty
    assert_equal [], ApacheAge.send(:traverse_edges, new_uuid, 'KNOWS', direction: :outgoing)
  end

  def test_forward_traverse_batch_empty
    assert_equal [], ApacheAge.send(:forward_traverse_batch, [new_uuid], 'KNOWS')
  end

  # -- exists_* --

  def test_vertex_exists_false_for_missing
    assert_equal false, ApacheAge.send(:vertex_exists?, object_id: new_uuid)
  end

  def test_edge_exists_false_for_missing
    assert_equal false, ApacheAge.send(:edge_exists?, new_uuid, new_uuid, 'KNOWS')
  end

  # -- delete_* --

  def test_delete_vertex_nonexistent
    # Deletes 0 rows but returns true (no error raised by DETACH DELETE)
    assert_equal true, ApacheAge.send(:delete_vertex, new_uuid)
  end

  def test_delete_edge_nonexistent
    # Deletes 0 rows but returns true (no error raised by DELETE)
    assert_equal true, ApacheAge.send(:delete_edge, new_uuid, new_uuid, 'KNOWS')
  end

  # -- execute_cypher_with_columns --

  def test_execute_cypher_with_columns_wrong_column_count
    # When columns don't match the Cypher return, AGE raises DatatypeMismatch
    assert_raises(PG::DatatypeMismatch) do
      ApacheAge.send(:execute_cypher_with_columns, 'MATCH ()-[e:KNOWS]->() RETURN e')
    end
  end

  # -- Working end-to-end with real data --

  def test_full_lifecycle
    v1 = new_uuid
    v2 = new_uuid

    # Create vertices (lowercase object_type for validation)
    assert_equal true, ApacheAge.send(:create_vertex, object_id: v1, object_type: 'person')
    assert_equal true, ApacheAge.send(:create_vertex, object_id: v2, object_type: 'person')

    # Create edge
    assert_equal true, ApacheAge.send(:create_edge, v1, v2, 'KNOWS')

    # Exists
    assert_equal true, ApacheAge.send(:vertex_exists?, object_id: v1)
    assert_equal true, ApacheAge.send(:edge_exists?, v1, v2, 'KNOWS')

    # Traverse
    results = ApacheAge.send(:traverse, v1, 'KNOWS', direction: :outgoing)
    assert_equal 1, results.length
    assert_equal v2, results.first.entity_id

    # Traverse edges
    edges = ApacheAge.send(:traverse_edges, v1, 'KNOWS', direction: :outgoing)
    assert_equal 1, edges.length

    # Delete edge
    assert_equal true, ApacheAge.send(:delete_edge, v1, v2, 'KNOWS')
    assert_equal false, ApacheAge.send(:edge_exists?, v1, v2, 'KNOWS')

    # Delete vertex
    assert_equal true, ApacheAge.send(:delete_vertex, v1)
    assert_equal false, ApacheAge.send(:vertex_exists?, object_id: v1)
  end

  # Regression: create_vertex must store object_type as a PROPERTY (not just a
  # label) so build_traverse_cypher's `RETURN target.object_type` is non-null,
  # and create_edge must MERGE on the existing vertex (not create a duplicate
  # :Entity-labeled one). Before the fix, create_vertex labeled by object_type
  # without setting the property, and create_edge used a :Entity label that
  # couldn't find the :person vertex — so traverse returned object_type=null
  # and two vertices existed for one object_id.
  def test_vertex_identity_round_trips_and_no_duplicate_on_edge
    v1 = new_uuid
    v2 = new_uuid

    assert_equal true, ApacheAge.send(:create_vertex, object_id: v1, object_type: 'person')
    assert_equal true, ApacheAge.send(:create_vertex, object_id: v2, object_type: 'person')
    assert_equal true, ApacheAge.send(:create_edge, v1, v2, 'KNOWS')

    # object_type must round-trip through traverse (was null before the fix)
    results = ApacheAge.send(:traverse, v1, 'KNOWS', direction: :outgoing)
    assert_equal 1, results.length
    assert_equal v2, results.first.entity_id
    assert_equal 'person', results.first.object_type,
                 'object_type must be stored as a property, not just a label'

    # create_edge must MERGE on the existing vertex, not create a duplicate.
    # Count vertices with this object_id — must be exactly 1.
    count_cypher = "MATCH (v {object_id: '#{v1}'}) RETURN count(v) AS result"
    rows = ApacheAge.query_cypher(count_cypher, columns: 'result ag_catalog.agtype')
    assert_equal 1, rows.first['result'],
                 'create_edge must not create a duplicate :Entity-labeled vertex'
  end

  # directionality: :undirected creates both (a)-[e]->(b) and (b)-[e2]->(a),
  # restoring pre-extraction semantics. :directed (the default) creates one.
  def test_create_edge_undirected_creates_both_directions
    v1 = new_uuid
    v2 = new_uuid

    assert_equal true, ApacheAge.send(:create_vertex, object_id: v1, object_type: 'person')
    assert_equal true, ApacheAge.send(:create_vertex, object_id: v2, object_type: 'person')

    assert_equal true, ApacheAge.create_edge(v1, v2, 'KNOWS', directionality: :undirected)

    # Both directions must exist.
    assert_equal true, ApacheAge.edge_exists?(v1, v2, 'KNOWS'), 'a->b edge missing'
    assert_equal true, ApacheAge.edge_exists?(v2, v1, 'KNOWS'), 'b->a edge missing (undirected should create both)'
  end

  private

  def new_uuid
    SecureRandom.uuid
  end
end
