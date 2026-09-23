# typed: false
# frozen_string_literal: true

require_relative 'test_helper'

# Unit tests for remaining uncovered paths in apache-age.rb helpers
# and edge cases not exercised by other tests.

class ApacheAgeRemainingCoverageTest < Minitest::Test
  # -- dollar_quote collision branch --

  def test_dollar_quote_with_collision
    cypher = "MATCH (n) WHERE n.name = '$$'
RETURN n"
    quote = ApacheAge.send(:dollar_quote, cypher)
    refute_equal '$$', quote
    # Random tag — each call generates a fresh random tag, so just
    # assert both calls produce valid $age_N$ delimiters.
    assert_match(/\$age_\d+\$/, quote)
    quote2 = ApacheAge.send(:dollar_quote, cypher)
    assert_match(/\$age_\d+\$/, quote2)
  end

  # -- parse_traverse_results with non-Hash input --
  # parse_agtype expects agtype-encoded values (double-quoted strings)

  def test_parse_traverse_results_non_hash_rows
    result = [
      { 'object_id' => '"abc12345-1234-1234-1234-123456789abc"',
        'object_type' => '"person"' }
    ]
    parsed = ApacheAge.send(:parse_traverse_results, result)
    assert_equal 1, parsed.length
    assert_equal 'abc12345-1234-1234-1234-123456789abc', parsed.first.entity_id
    assert_equal 'person', parsed.first.object_type
  end

  def test_parse_forward_traverse_results
    result = [
      { 'source_object_id' => '"a"', 'target_object_id' => '"b"',
        'target_object_type' => '"person"' }
    ]
    parsed = ApacheAge.send(:parse_forward_traverse_results, result)
    assert_equal 1, parsed.length
    assert_equal 'a', parsed.first.source_object_id
    assert_equal 'b', parsed.first.target_object_id
  end

  def test_parse_reverse_traverse_results
    result = [
      { 'source_object_id' => '"s"', 'target_object_id' => '"t"',
        'source_object_type' => '"person"' }
    ]
    parsed = ApacheAge.send(:parse_reverse_traverse_results, result)
    assert_equal 1, parsed.length
    assert_equal 's', parsed.first.source_object_id
    assert_equal 't', parsed.first.target_object_id
  end

  # -- Graph lifecycle error paths --
  # create_graph! wraps validate_graph_name!'s ArgumentError in GraphLifecycleError

  def test_create_graph_invalid_name_raises
    assert_raises(ApacheAge::GraphLifecycleError) do
      ApacheAge.create_graph!(name: 'inv@lid')
    end
  end

  def test_graph_exists_with_invalid_name
    refute ApacheAge.graph_exists?(name: 'bad-name')
  end

  # -- parse_agtype_numeric edge cases --

  def test_parse_agtype_numeric_empty_string
    assert_nil ApacheAge.send(:parse_agtype_numeric, '   ')
  end

  def test_parse_agtype_numeric_non_numeric
    assert_nil ApacheAge.send(:parse_agtype_numeric, '"hello"')
  end

  # -- build_properties_clause edge cases --
  # nil values are filtered out (don't appear in the clause)

  def test_build_properties_clause_with_nil_value
    clause = ApacheAge.send(:build_properties_clause, { 'name' => nil })
    refute_includes clause, 'name'
  end

  def test_build_properties_clause_with_string_value
    clause = ApacheAge.send(:build_properties_clause, { 'name' => 'Alice' })
    assert_includes clause, 'name'
    assert_includes clause, 'Alice'
  end

  # -- Validation methods --

  def test_validate_object_id_with_integer
    assert_raises(ArgumentError) do
      ApacheAge.send(:validate_object_id!, 123)
    end
  end

  def test_validate_object_type_with_uppercase
    assert_raises(ArgumentError) do
      ApacheAge.send(:validate_object_type!, 'PERSON')
    end
  end

  def test_validate_label_uppercase_required
    assert_raises(ArgumentError) do
      ApacheAge.send(:validate_label!, 'person')
    end
  end
end
