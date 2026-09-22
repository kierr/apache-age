# typed: strict
# frozen_string_literal: true

require_relative 'test_helper'

class ApacheAgeAgtypeParserEdgeCasesTest < Minitest::Test
  def test_low_surrogate_error
    # \uDC00 without a preceding high surrogate
    input = '"\\uDC00"'
    error = assert_raises(ApacheAge::AgtypeParser::ParseError) do
      ApacheAge.send(:parse_agtype, input)
    end
    assert_includes error.message, 'Low surrogate'
  end

  def test_parser_alnum_alias
    parser = ApacheAge::AgtypeParser.new('dummy')
    assert_equal parser.send(:ident_char?, 'a'), parser.send(:alnum?, 'a')
    assert_equal parser.send(:ident_char?, '0'), parser.send(:alnum?, '0')
    assert_equal parser.send(:ident_char?, '_'), parser.send(:alnum?, '_')
    refute parser.send(:alnum?, '$')
  end
end
