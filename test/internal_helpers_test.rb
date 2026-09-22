# typed: strict
# frozen_string_literal: true

require_relative 'test_helper'

class ApacheAgeInternalHelpersTest < Minitest::Test
  def test_escape_agtype_string
    escaped = ApacheAge.send(:escape_agtype_string, %(hello "world"))
    assert_equal %(hello \\"world\\"), escaped
  end

  def test_agtype_encode_string
    encoded = ApacheAge.send(:agtype_encode, 'hello')
    assert_equal '"hello"', encoded
  end

  def test_agtype_encode_integer
    encoded = ApacheAge.send(:agtype_encode, 42)
    assert_equal '42', encoded
  end

  def test_agtype_encode_float
    encoded = ApacheAge.send(:agtype_encode, 3.14)
    assert_in_delta 3.14, encoded.to_f, 0.01
  end

  def test_agtype_encode_true
    encoded = ApacheAge.send(:agtype_encode, true)
    assert_equal 'true', encoded
  end

  def test_agtype_encode_false
    encoded = ApacheAge.send(:agtype_encode, false)
    assert_equal 'false', encoded
  end

  def test_agtype_encode_nil
    encoded = ApacheAge.send(:agtype_encode, nil)
    assert_equal 'null', encoded
  end

  def test_agtype_encode_array
    encoded = ApacheAge.send(:agtype_encode, [1, 'a', nil])
    assert_equal '[1, "a", null]', encoded
  end

  def test_agtype_encode_hash
    encoded = ApacheAge.send(:agtype_encode, { 'name' => 'Alice', 'age' => 30 })
    assert_includes encoded, '"name"'
    assert_includes encoded, '"age"'
    assert_includes encoded, '30'
  end

  def test_dollar_quote_no_collision
    quote = ApacheAge.send(:dollar_quote, "MATCH (n) RETURN n")
    assert_equal '$$', quote
  end

  def test_dollar_quote_collision
    quote = ApacheAge.send(:dollar_quote, "MATCH (n) {name: $$hello$$} RETURN n")
    refute_equal '$$', quote
    assert quote.start_with?('$age_')
  end

  def test_reset_graph_availability
    ApacheAge.instance_variable_set(:@graph_available, true)
    ApacheAge.send(:reset_graph_availability!)
    assert_nil ApacheAge.instance_variable_get(:@graph_available)
  end

  def test_traverse_edges_columns_format
    cols = ApacheAge.send(:traverse_edges_columns)
    assert_equal 'object_id, object_type, confidence, first_seen, last_seen', cols
  end

  def test_validate_graph_name_valid
    assert_silent { ApacheAge.send(:validate_graph_name!, 'mygraph') }
    assert_silent { ApacheAge.send(:validate_graph_name!, 'Graph_1') }
  end

  def test_validate_graph_name_invalid_chars
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, 'my-graph') }
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, '123graph') }
  end

  def test_validate_graph_name_too_long
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, 'a' * 64) }
  end

  def test_validate_graph_name_too_short
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, '') }
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, 'a') }
  end

  def test_validate_label_valid
    # VALID_LABEL = /\A[A-Z][A-Z0-9_]*\z/
    assert_silent { ApacheAge.send(:validate_label!, 'PERSON') }
    assert_silent { ApacheAge.send(:validate_label!, 'ENTITY') }
    assert_silent { ApacheAge.send(:validate_label!, 'MY_ENTITY') }
  end

  def test_validate_label_invalid
    assert_raises(ArgumentError) { ApacheAge.send(:validate_label!, 'invalid-label') }
    assert_raises(ArgumentError) { ApacheAge.send(:validate_label!, '123label') }
    # lowercase not allowed (must start with A-Z)
    assert_raises(ArgumentError) { ApacheAge.send(:validate_label!, 'lowercase') }
    assert_raises(ArgumentError) { ApacheAge.send(:validate_label!, 'Person') }
  end

  def test_validate_object_id_valid
    # VALID_OBJECT_ID = UUID format
    uuid = 'abc12345-1234-1234-1234-123456789abc'
    assert_equal uuid, ApacheAge.send(:validate_object_id!, uuid)
  end

  def test_validate_object_id_invalid
    assert_raises(ArgumentError) { ApacheAge.send(:validate_object_id!, '') }
    assert_raises(ArgumentError) { ApacheAge.send(:validate_object_id!, 'abc_123') }
  end

  def test_validate_object_type_valid
    # VALID_OBJECT_TYPE = /\A[a-z_][a-z0-9_]*\z/
    assert_equal 'person', ApacheAge.send(:validate_object_type!, 'person')
    assert_equal 'my_entity', ApacheAge.send(:validate_object_type!, 'my_entity')
  end

  def test_validate_object_type_invalid
    assert_raises(ArgumentError) { ApacheAge.send(:validate_object_type!, '') }
    assert_raises(ArgumentError) { ApacheAge.send(:validate_object_type!, 'Person') }
  end

  def test_validate_column_name_valid
    assert_silent { ApacheAge.send(:validate_column_name!, 'v') }
    assert_silent { ApacheAge.send(:validate_column_name!, 'vertex_col') }
  end

  def test_validate_column_name_invalid
    assert_raises(ArgumentError) { ApacheAge.send(:validate_column_name!, 'v; DROP TABLE') }
    assert_raises(ArgumentError) { ApacheAge.send(:validate_column_name!, '') }
  end

  def test_validate_column_def_valid
    assert_silent { ApacheAge.send(:validate_column_def!, 'v ag_catalog.agtype, e ag_catalog.agtype') }
  end

  def test_validate_column_def_single_word
    assert_raises(ArgumentError) { ApacheAge.send(:validate_column_def!, 'v') }
  end

  def test_cypher_escape_simple
    escaped = ApacheAge.send(:cypher_escape, 'hello')
    assert_equal 'hello', escaped
  end

  def test_cypher_escape_quotes
    escaped = ApacheAge.send(:cypher_escape, "it's")
    assert_equal "it''s", escaped
  end

  def test_build_edge_cypher
    cypher = ApacheAge.send(:build_edge_cypher, 'from1', 'to1', 'KNOWS', { 'since' => 2020 })
    assert_includes cypher, 'from1'
    assert_includes cypher, 'to1'
    assert_includes cypher, 'KNOWS'
    assert_includes cypher, 'since'
  end

  def test_build_traverse_cypher_outgoing
    cypher = ApacheAge.send(:build_traverse_cypher, %w[id1 id2], 'KNOWS', :outgoing)
    assert_includes cypher, 'id1'
    assert_includes cypher, 'id2'
    assert_includes cypher, 'KNOWS'
    assert_includes cypher, '->'
  end

  def test_build_traverse_cypher_incoming
    cypher = ApacheAge.send(:build_traverse_cypher, %w[id1], 'KNOWS', :incoming)
    assert_includes cypher, '<-'
  end

  def test_build_traverse_cypher_both
    cypher = ApacheAge.send(:build_traverse_cypher, %w[id1], 'KNOWS', :both)
    assert_includes cypher, '-'
    refute_includes cypher, '->'
    refute_includes cypher, '<-'
  end

  def test_build_traverse_edges_cypher_outgoing
    cypher = ApacheAge.send(:build_traverse_edges_cypher, 'id1', 'KNOWS', :outgoing)
    assert_includes cypher, 'id1'
    assert_includes cypher, 'KNOWS'
    assert_includes cypher, '->'
  end

  def test_build_traverse_edges_cypher_incoming
    cypher = ApacheAge.send(:build_traverse_edges_cypher, 'id1', 'KNOWS', :incoming)
    assert_includes cypher, '<-'
  end

  def test_build_traverse_edges_cypher_both
    cypher = ApacheAge.send(:build_traverse_edges_cypher, 'id1', 'KNOWS', :both)
    assert_includes cypher, '-'
    refute_includes cypher, '->'
    refute_includes cypher, '<-'
  end

  def test_parse_agtype_numeric_valid
    parsed = ApacheAge.send(:parse_agtype_numeric, '123.45')
    assert_in_delta 123.45, parsed, 0.001
  end

  def test_parse_agtype_numeric_nil_raises
    assert_raises(ArgumentError) { ApacheAge.send(:parse_agtype_numeric, nil) }
  end

  def test_parse_agtype_numeric_empty
    assert_nil ApacheAge.send(:parse_agtype_numeric, '')
  end

  def test_parse_agtype_numeric_invalid
    assert_nil ApacheAge.send(:parse_agtype_numeric, 'not_a_number')
  end

  def test_build_properties_clause_empty
    # Empty hash returns empty string — the caller wraps in {} when needed
    clause = ApacheAge.send(:build_properties_clause, {})
    assert_equal '', clause
  end

  def test_build_properties_clause_with_values
    clause = ApacheAge.send(:build_properties_clause, { 'name' => 'Alice', 'age' => 30 })
    assert_includes clause, 'name'
    assert_includes clause, 'Alice'
    assert_includes clause, 'age'
  end
end
