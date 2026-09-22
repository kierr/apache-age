# typed: strict
# frozen_string_literal: true

require_relative 'test_helper'
require 'bigdecimal'

class AgtypeParserTest < Minitest::Test
  # --- String parsing ---

  def test_simple_string
    assert_equal 'hello', ApacheAge::AgtypeParser.parse('"hello"')
  end

  def test_empty_string
    assert_equal '', ApacheAge::AgtypeParser.parse('""')
  end

  def test_string_with_escaped_quote
    assert_equal 'say "hi"', ApacheAge::AgtypeParser.parse('"say \\"hi\\""')
  end

  def test_string_with_escaped_backslash
    assert_equal 'path\\to\\file', ApacheAge::AgtypeParser.parse('"path\\\\to\\\\file"')
  end

  def test_string_with_escaped_newline
    assert_equal "line1\nline2", ApacheAge::AgtypeParser.parse('"line1\\nline2"')
  end

  def test_string_with_escaped_tab
    assert_equal "col1\tcol2", ApacheAge::AgtypeParser.parse('"col1\\tcol2"')
  end

  def test_string_with_escaped_carriage_return
    assert_equal "line1\rline2", ApacheAge::AgtypeParser.parse('"line1\\rline2"')
  end

  def test_string_with_unicode_escape
    assert_equal 'café', ApacheAge::AgtypeParser.parse('"caf\\u00e9"')
  end

  def test_string_with_forward_slash_escape
    assert_equal 'a/b', ApacheAge::AgtypeParser.parse('"a\\/b"')
  end

  def test_string_with_backspace_escape
    assert_equal "a\bf", ApacheAge::AgtypeParser.parse('"a\\bf"')
  end

  def test_string_with_formfeed_escape
    assert_equal "a\ff", ApacheAge::AgtypeParser.parse('"a\\ff"')
  end

  # --- Integer parsing ---

  def test_positive_integer
    assert_equal 42, ApacheAge::AgtypeParser.parse('42')
  end

  def test_zero
    assert_equal 0, ApacheAge::AgtypeParser.parse('0')
  end

  def test_negative_integer
    assert_equal(-7, ApacheAge::AgtypeParser.parse('-7'))
  end

  def test_large_integer
    assert_equal 9_223_372_036_854_775_807, ApacheAge::AgtypeParser.parse('9223372036854775807')
  end

  # --- Float parsing ---

  def test_simple_float
    assert_in_delta 3.14, ApacheAge::AgtypeParser.parse('3.14'), 0.001
  end

  def test_negative_float
    assert_in_delta(-2.5, ApacheAge::AgtypeParser.parse('-2.5'), 0.001)
  end

  def test_scientific_notation
    assert_in_delta 1.5e10, ApacheAge::AgtypeParser.parse('1.5e10'), 1.0
  end

  def test_scientific_notation_uppercase
    assert_in_delta 2.0e5, ApacheAge::AgtypeParser.parse('2.0E5'), 1.0
  end

  def test_scientific_notation_negative_exponent
    assert_in_delta 1.0e-3, ApacheAge::AgtypeParser.parse('1.0e-3'), 0.0001
  end

  # --- Special float values ---

  def test_nan
    result = ApacheAge::AgtypeParser.parse('NaN')
    assert result.nan?, "Expected NaN, got #{result.inspect}"
  end

  def test_infinity
    result = ApacheAge::AgtypeParser.parse('Infinity')
    assert_equal Float::INFINITY, result
  end

  def test_negative_infinity
    result = ApacheAge::AgtypeParser.parse('-Infinity')
    assert_equal(-Float::INFINITY, result)
  end

  # --- Boolean parsing ---

  def test_true
    assert_equal true, ApacheAge::AgtypeParser.parse('true')
  end

  def test_false
    assert_equal false, ApacheAge::AgtypeParser.parse('false')
  end

  # --- Null parsing ---

  def test_null
    assert_nil ApacheAge::AgtypeParser.parse('null')
  end

  # --- Empty input ---

  def test_nil_input
    assert_nil ApacheAge::AgtypeParser.parse(nil)
  end

  def test_empty_string_input
    assert_nil ApacheAge::AgtypeParser.parse('')
  end

  def test_whitespace_only_input
    assert_nil ApacheAge::AgtypeParser.parse('   ')
  end

  # --- Object parsing ---

  def test_empty_object
    assert_equal({}, ApacheAge::AgtypeParser.parse('{}'))
  end

  def test_simple_object
    result = ApacheAge::AgtypeParser.parse('{"name": "Alice", "age": 30}')
    assert_equal({ 'name' => 'Alice', 'age' => 30 }, result)
  end

  def test_object_with_null_value
    result = ApacheAge::AgtypeParser.parse('{"key": null}')
    assert_equal({ 'key' => nil }, result)
  end

  def test_object_with_boolean_values
    result = ApacheAge::AgtypeParser.parse('{"active": true, "deleted": false}')
    assert_equal({ 'active' => true, 'deleted' => false }, result)
  end

  def test_nested_object
    result = ApacheAge::AgtypeParser.parse('{"outer": {"inner": 42}}')
    assert_equal({ 'outer' => { 'inner' => 42 } }, result)
  end

  def test_object_with_array_value
    result = ApacheAge::AgtypeParser.parse('{"tags": [1, 2, 3]}')
    assert_equal({ 'tags' => [1, 2, 3] }, result)
  end

  # --- Array parsing ---

  def test_empty_array
    assert_equal [], ApacheAge::AgtypeParser.parse('[]')
  end

  def test_simple_array
    assert_equal [1, 2, 3], ApacheAge::AgtypeParser.parse('[1, 2, 3]')
  end

  def test_mixed_type_array
    result = ApacheAge::AgtypeParser.parse('[1, "two", true, null]')
    assert_equal [1, 'two', true, nil], result
  end

  def test_nested_arrays
    assert_equal [[1, 2], [3, 4]], ApacheAge::AgtypeParser.parse('[[1, 2], [3, 4]]')
  end

  # --- Type annotations ---

  def test_numeric_type_annotation
    result = ApacheAge::AgtypeParser.parse('3.14159265358979323846::numeric')
    assert_instance_of BigDecimal, result
    assert_in_delta 3.14159265358979323846, result.to_f, 0.000000001
  end

  def test_integer_numeric_type_annotation
    result = ApacheAge::AgtypeParser.parse('42::numeric')
    assert_instance_of BigDecimal, result
    assert_equal BigDecimal('42'), result
  end

  def test_vertex_type_annotation
    input = '{"id": 1, "label": "Person", "properties": {"name": "Alice"}}::vertex'
    result = ApacheAge::AgtypeParser.parse(input)
    assert_instance_of ApacheAge::Vertex, result
    assert_equal 1, result.id
    assert_equal 'Person', result.label
    assert_equal({ 'name' => 'Alice' }, result.properties)
  end

  def test_edge_type_annotation
    input = '{"id": 2, "label": "KNOWS", "start_id": 1, "end_id": 3, "properties": {"since": 2020}}::edge'
    result = ApacheAge::AgtypeParser.parse(input)
    assert_instance_of ApacheAge::Edge, result
    assert_equal 2, result.id
    assert_equal 'KNOWS', result.label
    assert_equal 1, result.start_id
    assert_equal 3, result.end_id
    assert_equal({ 'since' => 2020 }, result.properties)
  end

  def test_path_type_annotation
    input = '[{"id": 1, "label": "A", "properties": {}}::vertex, {"id": 2, "label": "E", "start_id": 1, "end_id": 3, "properties": {}}::edge, {"id": 3, "label": "B", "properties": {}}::vertex]::path'
    result = ApacheAge::AgtypeParser.parse(input)
    assert_instance_of ApacheAge::Path, result
    assert_equal 2, result.vertices.length
    assert_equal 1, result.edges.length
    assert_equal 1, result.length
  end

  def test_unknown_type_annotation
    result = ApacheAge::AgtypeParser.parse('42::custom_type')
    assert_equal 42, result
  end

  # --- Complex real-world AGE output ---

  def test_vertex_with_nested_properties
    input = '{"id": 844424930131971, "label": "Person", "properties": {"name": "Bob", "age": 35, "active": true}}::vertex'
    result = ApacheAge::AgtypeParser.parse(input)
    assert_instance_of ApacheAge::Vertex, result
    assert_equal 'Bob', result.properties['name']
    assert_equal 35, result.properties['age']
    assert_equal true, result.properties['active']
  end

  def test_edge_with_empty_properties
    input = '{"id": 1407374883553281, "label": "LINKS_TO", "start_id": 844424930131971, "end_id": 844424930131972, "properties": {}}::edge'
    result = ApacheAge::AgtypeParser.parse(input)
    assert_instance_of ApacheAge::Edge, result
    assert_equal({}, result.properties)
  end

  # --- Whitespace handling ---

  def test_object_with_whitespace
    result = ApacheAge::AgtypeParser.parse('{ "key" : "value" }')
    assert_equal({ 'key' => 'value' }, result)
  end

  def test_array_with_whitespace
    result = ApacheAge::AgtypeParser.parse('[ 1 , 2 , 3 ]')
    assert_equal [1, 2, 3], result
  end

  # --- Error handling ---

  def test_unexpected_character
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse('@invalid') }
  end

  def test_trailing_content
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse('42 extra') }
  end

  # --- Keyword boundary checks ---

  def test_keyword_boundary_truely
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse('truely') }
  end

  def test_keyword_boundary_falsely
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse('falsely') }
  end

  def test_keyword_boundary_nullify
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse('nullify') }
  end

  def test_keyword_boundary_nanometer
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse('NaNometer') }
  end

  def test_keyword_boundary_infinity_plus
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse('InfinityPlus') }
  end

  # --- Leading zeros ---

  def test_leading_zeros_rejected
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse('007') }
  end

  def test_zero_is_valid
    assert_equal 0, ApacheAge::AgtypeParser.parse('0')
  end

  def test_zero_point_five_is_valid
    assert_in_delta 0.5, ApacheAge::AgtypeParser.parse('0.5'), 0.001
  end

  # --- Negative zero ---

  def test_negative_zero_integer
    assert_equal 0, ApacheAge::AgtypeParser.parse('-0')
  end

  def test_negative_zero_float
    assert_in_delta 0.0, ApacheAge::AgtypeParser.parse('-0.0'), 0.001
  end

  # --- Float edge cases ---

  def test_float_zero
    assert_in_delta 0.0, ApacheAge::AgtypeParser.parse('0.0'), 0.001
  end

  def test_scientific_with_positive_exponent
    assert_in_delta 1.0e5, ApacheAge::AgtypeParser.parse('1E+5'), 1.0
  end

  def test_scientific_with_negative_exponent
    assert_in_delta 1.0e-3, ApacheAge::AgtypeParser.parse('1e-3'), 0.0001
  end

  def test_scientific_without_decimal
    assert_in_delta 1.0e5, ApacheAge::AgtypeParser.parse('1e5'), 1.0
  end

  # --- Deeply nested structures ---

  def test_deeply_nested_object
    input = '{"a": {"b": {"c": {"d": 1}}}}'
    result = ApacheAge::AgtypeParser.parse(input)
    assert_equal({ 'a' => { 'b' => { 'c' => { 'd' => 1 } } } }, result)
  end

  # --- Depth limit ---

  def test_depth_limit_exceeded
    # Build a deeply nested structure exceeding the default depth
    old_max = ApacheAge::AgtypeParser.max_depth
    ApacheAge::AgtypeParser.max_depth = 5
    input = '{"a": {"b": {"c": {"d": {"e": {"f": 1}}}}}}'
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse(input) }
  ensure
    ApacheAge::AgtypeParser.max_depth = old_max
  end

  # --- Bare minus raises ---

  def test_bare_minus_raises
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse('-') }
  end

  # --- Int64 boundary ---

  def test_int64_max
    assert_equal 9_223_372_036_854_775_807, ApacheAge::AgtypeParser.parse('9223372036854775807')
  end

  # --- Surrogate pairs ---

  def test_unicode_surrogate_pair
    result = ApacheAge::AgtypeParser.parse('"\\uD83D\\uDE00"')
    assert_equal '😀', result
  end

  def test_high_surrogate_without_low_raises
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse('"\\uD800"') }
  end

  def test_low_surrogate_without_high_raises
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge::AgtypeParser.parse('"\\uDC00"') }
  end
end

class ApacheAgeVertexTest < Minitest::Test
  def test_bracket_access
    v = ApacheAge::Vertex.new(id: 1, label: 'Person', properties: { 'name' => 'Alice' })
    assert_equal 1, v[:id]
    assert_equal 'Person', v[:label]
    assert_equal({ 'name' => 'Alice' }, v[:properties])
  end

  def test_to_h
    v = ApacheAge::Vertex.new(id: 1, label: 'Person', properties: { 'name' => 'Alice' })
    h = v.to_h
    assert_equal 1, h[:id]
    assert_equal 'Person', h[:label]
    assert_equal({ 'name' => 'Alice' }, h[:properties])
  end

  def test_to_s
    v = ApacheAge::Vertex.new(id: 1, label: 'Person', properties: {})
    assert_match(/::VERTEX/, v.to_s)
  end

  def test_inspect
    v = ApacheAge::Vertex.new(id: 1, label: 'Person', properties: {})
    assert_match(/Vertex/, v.inspect)
  end

  def test_to_agtype
    v = ApacheAge::Vertex.new(id: 1, label: 'Person', properties: { 'name' => 'Alice' })
    result = v.to_agtype
    assert_match(/"id": 1/, result)
    assert_match(/"label": "Person"/, result)
    assert_match(/::vertex/, result)
  end

  def test_fields_constant
    assert_equal %i[id label properties], ApacheAge::Vertex::FIELDS
  end
end

class ApacheAgeEdgeTest < Minitest::Test
  def test_bracket_access
    e = ApacheAge::Edge.new(id: 2, label: 'KNOWS', start_id: 1, end_id: 3, properties: {})
    assert_equal 2, e[:id]
    assert_equal 'KNOWS', e[:label]
    assert_equal 1, e[:start_id]
    assert_equal 3, e[:end_id]
  end

  def test_to_h
    e = ApacheAge::Edge.new(id: 2, label: 'KNOWS', start_id: 1, end_id: 3, properties: { 'since' => 2020 })
    h = e.to_h
    assert_equal 2, h[:id]
    assert_equal 1, h[:start_id]
  end

  def test_to_s
    e = ApacheAge::Edge.new(id: 2, label: 'KNOWS', start_id: 1, end_id: 3, properties: {})
    assert_match(/::EDGE/, e.to_s)
  end

  def test_to_agtype
    e = ApacheAge::Edge.new(id: 2, label: 'KNOWS', start_id: 1, end_id: 3, properties: {})
    result = e.to_agtype
    assert_match(/"id": 2/, result)
    assert_match(/"start_id": 1/, result)
    assert_match(/::edge/, result)
  end

  def test_fields_constant
    assert_equal %i[id label start_id end_id properties], ApacheAge::Edge::FIELDS
  end
end

class ApacheAgePathTest < Minitest::Test
  def test_vertices_and_edges
    v1 = ApacheAge::Vertex.new(id: 1, label: 'A', properties: {})
    e1 = ApacheAge::Edge.new(id: 2, label: 'E', start_id: 1, end_id: 3, properties: {})
    v2 = ApacheAge::Vertex.new(id: 3, label: 'B', properties: {})
    path = ApacheAge::Path.new(entities: [v1, e1, v2])

    assert_equal [v1, v2], path.vertices
    assert_equal [e1], path.edges
    assert_equal 1, path.length
  end

  def test_empty_path
    path = ApacheAge::Path.new(entities: [])
    assert_equal [], path.vertices
    assert_equal [], path.edges
    assert_equal 0, path.length
  end

  def test_to_agtype
    v1 = ApacheAge::Vertex.new(id: 1, label: 'A', properties: {})
    e1 = ApacheAge::Edge.new(id: 2, label: 'E', start_id: 1, end_id: 3, properties: {})
    v2 = ApacheAge::Vertex.new(id: 3, label: 'B', properties: {})
    path = ApacheAge::Path.new(entities: [v1, e1, v2])
    result = path.to_agtype
    assert_match(/::path/, result)
    assert_match(/::vertex/, result)
    assert_match(/::edge/, result)
  end
end

class ApacheAgeModuleTest < Minitest::Test
  def test_version
    assert_equal '0.1.0', ApacheAge::VERSION
  end

  # --- parse_agtype ---

  def test_parse_agtype_string
    assert_equal 'hello', ApacheAge.parse_agtype('"hello"')
  end

  def test_parse_agtype_integer
    assert_equal 42, ApacheAge.parse_agtype('42')
  end

  def test_parse_agtype_vertex
    input = '{"id": 1, "label": "Person", "properties": {"name": "Alice"}}::vertex'
    result = ApacheAge.parse_agtype(input)
    assert_instance_of ApacheAge::Vertex, result
    assert_equal 1, result.id
  end

  def test_parse_agtype_nil
    assert_nil ApacheAge.parse_agtype(nil)
  end

  def test_parse_agtype_empty
    assert_nil ApacheAge.parse_agtype('')
  end

  def test_parse_agtype_malformed_raises_by_default
    assert_raises(ApacheAge::AgtypeParser::ParseError) { ApacheAge.parse_agtype('just_a_plain_string') }
  end

  def test_parse_agtype_malformed_lenient_returns_nil
    assert_nil ApacheAge.parse_agtype('just_a_plain_string', lenient: true)
  end

  # --- cypher_escape ---

  def test_cypher_escape_quotes
    assert_equal "it''s", ApacheAge.cypher_escape("it's")
  end

  def test_cypher_escape_no_quotes
    assert_equal 'hello', ApacheAge.cypher_escape('hello')
  end

  # --- agtype_encode ---

  def test_agtype_encode_nil
    assert_equal 'null', ApacheAge.agtype_encode(nil)
  end

  def test_agtype_encode_integer
    assert_equal '42', ApacheAge.agtype_encode(42)
  end

  def test_agtype_encode_float
    assert_equal '3.14', ApacheAge.agtype_encode(3.14)
  end

  def test_agtype_encode_nan
    assert_equal 'NaN', ApacheAge.agtype_encode(Float::NAN)
  end

  def test_agtype_encode_infinity
    assert_equal 'Infinity', ApacheAge.agtype_encode(Float::INFINITY)
  end

  def test_agtype_encode_string
    assert_equal '"hello"', ApacheAge.agtype_encode('hello')
  end

  def test_agtype_encode_string_with_control_chars
    assert_equal '"line1\\nline2"', ApacheAge.agtype_encode("line1\nline2")
    assert_equal '"tab\\there"', ApacheAge.agtype_encode("tab\there")
  end

  def test_agtype_encode_symbol
    assert_equal '"hello"', ApacheAge.agtype_encode(:hello)
  end

  def test_agtype_encode_bigdecimal
    result = ApacheAge.agtype_encode(BigDecimal('3.14'))
    assert_match(/3\.14::numeric/, result)
  end

  def test_agtype_encode_array
    assert_equal '[1, "two", true]', ApacheAge.agtype_encode([1, 'two', true])
  end

  def test_agtype_encode_hash
    result = ApacheAge.agtype_encode({ 'name' => 'Alice' })
    assert_match(/"name": "Alice"/, result)
  end

  def test_agtype_encode_hash_with_symbol_key
    result = ApacheAge.agtype_encode({ name: 'Alice' })
    assert_match(/"name": "Alice"/, result)
  end

  def test_agtype_encode_unsupported_type_raises
    assert_raises(TypeError) { ApacheAge.agtype_encode(Object.new) }
  end

  def test_agtype_encode_vertex
    v = ApacheAge::Vertex.new(id: 1, label: 'Person', properties: { 'name' => 'Alice' })
    result = ApacheAge.agtype_encode(v)
    assert_match(/::vertex/, result)
  end

  def test_agtype_encode_edge
    e = ApacheAge::Edge.new(id: 2, label: 'KNOWS', start_id: 1, end_id: 3, properties: {})
    result = ApacheAge.agtype_encode(e)
    assert_match(/::edge/, result)
  end

  # --- dollar_quote ---

  def test_dollar_quote_simple
    assert_equal '$$', ApacheAge.send(:dollar_quote, 'MATCH (n) RETURN n')
  end

  def test_dollar_quote_with_dollar_dollar
    result = ApacheAge.send(:dollar_quote, 'MATCH (n {name: $$}) RETURN n')
    assert_match(/\$age_\d+\$/, result)
    refute_equal '$tag$', result
  end

  def test_dollar_quote_returns_valid_delimiter
    cypher = 'contains $$'
    delimiter = ApacheAge.send(:dollar_quote, cypher)
    refute_includes cypher, delimiter
  end

  # --- parse_agtype_numeric ---

  def test_parse_agtype_numeric_nil_raises
    assert_raises(ArgumentError) { ApacheAge.parse_agtype_numeric(nil) }
  end

  # --- Validation ---

  def test_validate_graph_name_valid
    ApacheAge.send(:validate_graph_name!, 'my_graph')
    ApacheAge.send(:validate_graph_name!, 'MyGraph')
    ApacheAge.send(:validate_graph_name!, '_private')
  end

  def test_validate_graph_name_invalid
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, '1invalid') }
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, '') }
  end

  def test_validate_graph_name_too_short
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, 'ab') }
  end

  def test_validate_graph_name_too_long
    assert_raises(ArgumentError) { ApacheAge.send(:validate_graph_name!, 'a' * 64) }
  end

  def test_validate_graph_name_at_max
    ApacheAge.send(:validate_graph_name!, 'a' * 63)
  end

  def test_validate_label_name_valid
    ApacheAge.send(:validate_label_name!, 'Person')
    ApacheAge.send(:validate_label_name!, 'my_label')
  end

  def test_validate_label_name_invalid
    assert_raises(ArgumentError) { ApacheAge.send(:validate_label_name!, 'has-dash') }
    assert_raises(ArgumentError) { ApacheAge.send(:validate_label_name!, '1invalid') }
  end

  def test_validate_column_name_valid
    ApacheAge.send(:validate_column_name!, 'v')
    ApacheAge.send(:validate_column_name!, 'my_col')
  end

  def test_validate_column_name_invalid
    assert_raises(ArgumentError) { ApacheAge.send(:validate_column_name!, '1bad') }
    assert_raises(ArgumentError) { ApacheAge.send(:validate_column_name!, 'drop table') }
  end

  # --- Connection ---

  def test_connection_savepoint_name_validation
    assert_raises(ArgumentError) { ApacheAge::Connection.with_savepoint("'; DROP TABLE users; --") {} }
    assert_raises(ArgumentError) { ApacheAge::Connection.with_savepoint('1invalid') {} }
  end

  def test_connection_disconnect_without_connection
    # Should not raise even when no connection is set
    ApacheAge::Connection.disconnect
  end
end
