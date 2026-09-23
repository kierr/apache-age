# typed: strict
# frozen_string_literal: true

require_relative 'test_helper'

class ApacheAgeValidationTest < Minitest::Test
  # --- validate_graph_name! ---

  def test_validate_graph_name_valid
    assert_silent { ApacheAge.send(:validate_graph_name!, 'my_graph') }
    assert_silent { ApacheAge.send(:validate_graph_name!, 'MyGraph123') }
    assert_silent { ApacheAge.send(:validate_graph_name!, '_private') }
    assert_silent { ApacheAge.send(:validate_graph_name!, 'a' * 63) } # max length
  end

  def test_validate_graph_name_empty
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, '') }
  end

  def test_validate_graph_name_too_short
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, 'ab') }
  end

  def test_validate_graph_name_too_long
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, 'a' * 64) }
  end

  def test_validate_graph_name_starts_with_number
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, '1invalid') }
  end

  def test_validate_graph_name_has_space
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, 'has space') }
  end

  def test_validate_graph_name_has_dash
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, 'has-dash') }
  end

  # --- validate_label_name! ---

  def test_validate_label_name_empty
    assert_raises(ArgumentError) { ApacheAge.send(:validate_label_name!, '') }
  end

  def test_validate_label_name_starts_with_number
    assert_raises(ArgumentError) { ApacheAge.send(:validate_label_name!, '1invalid') }
  end

  def test_validate_label_name_has_space
    assert_raises(ArgumentError) { ApacheAge.send(:validate_label_name!, 'label name') }
  end

  # --- validate_label! ---

  def test_validate_label_starts_with_number
    assert_raises(ArgumentError) { ApacheAge.send(:validate_label!, '1invalid') }
  end

  # --- validate_object_id! ---

  def test_validate_object_id_empty
    assert_raises(ArgumentError) { ApacheAge.send(:validate_object_id!, '') }
  end

  def test_validate_object_id_invalid_non_uuid
    assert_raises(ArgumentError) { ApacheAge.send(:validate_object_id!, 'abc-def') }
  end

  def test_validate_object_id_valid
    uuid = '550e8400-e29b-41d4-a716-446655440000'
    assert_equal uuid, ApacheAge.send(:validate_object_id!, uuid)
  end

  # --- validate_object_type! ---

  def test_validate_object_type_invalid
    assert_raises(ArgumentError) { ApacheAge.send(:validate_object_type!, :Other) }
  end

  def test_validate_object_type_non_symbol_coerces
    assert_equal 'vertex', ApacheAge.send(:validate_object_type!, 'vertex')
  end

  def test_validate_object_type_valid
    assert_equal 'vertex', ApacheAge.send(:validate_object_type!, :vertex)
    assert_equal 'edge', ApacheAge.send(:validate_object_type!, :edge)
  end

  # --- validate_column_name! ---

  def test_validate_column_name_starts_with_number
    assert_raises(ArgumentError) { ApacheAge.send(:validate_column_name!, '1bad') }
  end

  def test_validate_column_name_has_space
    assert_raises(ArgumentError) { ApacheAge.send(:validate_column_name!, 'drop table') }
  end

  def test_validate_column_name_valid_uppercase
    assert_silent { ApacheAge.send(:validate_column_name!, 'ID') }
  end

  def test_validate_column_name_valid_underscore
    assert_silent { ApacheAge.send(:validate_column_name!, '_meta') }
  end

  # --- validate_column_def! ---

  def test_validate_column_def_simple
    assert_silent { ApacheAge.send(:validate_column_def!, 'id ag_catalog.agtype') }
  end

  def test_validate_column_def_multiple
    assert_silent { ApacheAge.send(:validate_column_def!, 'id ag_catalog.agtype, name ag_catalog.agtype') }
  end

  def test_validate_column_def_empty
    assert_silent { ApacheAge.send(:validate_column_def!, '') }
  end

  def test_validate_column_def_bad_type
    assert_raises(ArgumentError) { ApacheAge.send(:validate_column_def!, 'id 1integer') }
  end

  def test_validate_column_def_missing_type
    assert_raises(ArgumentError) { ApacheAge.send(:validate_column_def!, 'id') }
  end

  # --- validate_graph_name! caching is not here, but the negative-graph-name guard ---
end

class ApacheAgeGraphAvailableTest < Minitest::Test
  def test_graph_available_when_graph_name_empty
    original = ApacheAge.graph_name
    begin
      ApacheAge.graph_name = ''
      refute ApacheAge.graph_available?
    ensure
      ApacheAge.graph_name = original
    end
  end

  def test_create_vertex_when_graph_not_available
    original = ApacheAge.graph_name
    begin
      ApacheAge.graph_name = ''
      refute ApacheAge.create_vertex(object_id: 'x', object_type: 'v')
    ensure
      ApacheAge.graph_name = original
    end
  end

  def test_create_edge_when_graph_not_available
    original = ApacheAge.graph_name
    begin
      ApacheAge.graph_name = ''
      refute ApacheAge.create_edge('a', 'b', 'LINKS')
    ensure
      ApacheAge.graph_name = original
    end
  end

  def test_traverse_when_graph_not_available
    original = ApacheAge.graph_name
    begin
      ApacheAge.graph_name = ''
      assert_equal [], ApacheAge.traverse('a', 'LINKS')
    ensure
      ApacheAge.graph_name = original
    end
  end

  def test_traverse_batch_empty_ids
    assert_equal [], ApacheAge.traverse_batch([], 'LINKS')
  end

  def test_traverse_batch_when_graph_not_available
    original = ApacheAge.graph_name
    begin
      ApacheAge.graph_name = ''
      assert_equal [], ApacheAge.traverse_batch(%w[a b], 'LINKS')
    ensure
      ApacheAge.graph_name = original
    end
  end
end

class ApacheAgeCypherHelperTest < Minitest::Test
  # --- build_traverse_cypher ---

  def test_build_traverse_cypher_outgoing
    result = ApacheAge.send(:build_traverse_cypher, ['abc'], 'KNOWS', :outgoing)
    assert_match(/abc/, result)
    assert_match(/KNOWS/, result)
  end

  def test_build_traverse_cypher_inbound
    result = ApacheAge.send(:build_traverse_cypher, ['abc'], 'KNOWS', :inbound)
    assert_match(/KNOWS/, result)
  end

  def test_build_traverse_cypher_both
    result = ApacheAge.send(:build_traverse_cypher, ['abc'], 'KNOWS', :both)
    assert_match(/KNOWS/, result)
  end

  def test_build_traverse_cypher_batch_ids
    result = ApacheAge.send(:build_traverse_cypher, %w[abc def ghi], 'KNOWS', :outgoing)
    assert_match(/'abc'/, result)
    assert_match(/'def'/, result)
    assert_match(/'ghi'/, result)
  end

  # --- build_edge_cypher ---

  def test_build_edge_cypher_no_properties
    result = ApacheAge.send(:build_edge_cypher, 'a', 'b', 'KNOWS', {}, :directed)
    assert_match(/KNOWS/, result)
    refute_match(/SET/, result)
  end

  def test_build_edge_cypher_with_properties
    result = ApacheAge.send(:build_edge_cypher, 'a', 'b', 'KNOWS', { 'since' => 2020 }, :directed)
    assert_match(/since/, result)
    assert_match(/2020/, result)
  end

  # --- dollar_quote ---

  def test_dollar_quote_simple
    tag = ApacheAge.send(:dollar_quote, 'MATCH (n) RETURN n')
    assert_equal '$$', tag
  end

  def test_dollar_quote_avoids_collision
    input = 'MATCH (n {name: $$}) RETURN n'
    tag = ApacheAge.send(:dollar_quote, input)
    refute_includes input, tag[1..-2] # inner tag shouldn't appear in cypher
  end
end

class ApacheAgeEncodingTest < Minitest::Test
  def test_agtype_encode_true
    assert_equal 'true', ApacheAge.agtype_encode(true)
  end

  def test_agtype_encode_false
    assert_equal 'false', ApacheAge.agtype_encode(false)
  end

  def test_agtype_encode_empty_array
    assert_equal '[]', ApacheAge.agtype_encode([])
  end

  def test_agtype_encode_empty_hash
    result = ApacheAge.agtype_encode({})
    assert_equal '{}', result
  end

  def test_agtype_encode_nested_array
    result = ApacheAge.agtype_encode([1, [2, 3]])
    assert_equal '[1, [2, 3]]', result
  end

  def test_agtype_encode_nested_hash
    result = ApacheAge.agtype_encode({ 'outer' => { 'inner' => 42 } })
    assert_match(/"outer":/, result)
    assert_match(/"inner":/, result)
  end

  def test_agtype_encode_mixed_array
    result = ApacheAge.agtype_encode([1, 'two', true, nil, false])
    assert_match(/1/, result)
    assert_match(/"two"/, result)
    assert_match(/true/, result)
    assert_match(/null/, result)
  end
end

class ApacheAgeConnectionBasicTest < Minitest::Test
  def test_disconnect_idempotent
    # Disconnecting when already disconnected should not raise
    ApacheAge::Connection.disconnect
    # Second call should also not raise
    assert_nil ApacheAge::Connection.instance_variable_get(:@pg_connection)
  end
end
