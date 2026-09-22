# typed: strict
# frozen_string_literal: true

module ApacheAge
  # Full recursive-descent parser for Apache AGE's agtype format.
  #
  # Implements the Agtype.g4 grammar as a hand-written parser, matching the
  # approach of the official Go, Python, JDBC, and Node.js drivers (which all
  # use ANTLR-generated parsers from the same grammar).
  #
  # Handles:
  #   - Type annotations (::vertex, ::edge, ::path, ::numeric)
  #   - Nested objects and arrays
  #   - Escaped strings (\", \\, \/, \b, \f, \n, \r, \t, \uXXXX)
  #   - null, true, false literals
  #   - Integer, float, scientific notation
  #   - NaN, Infinity, -Infinity
  #   - Arbitrary-precision ::numeric via BigDecimal
  #   - Unicode surrogate pairs (\uD800\uDC00)
  #
  class AgtypeParser
    extend T::Sig

    class ParseError < StandardError; end

    # RATIONALE: Depth limit prevents stack overflow on deeply nested input.
    # Default 100 matches JSON parsers like Oj and yajl. Configurable for
    # callers with legitimate deep-nesting needs. Would need a proven use case
    # beyond 100 to raise the default.
    DEFAULT_MAX_DEPTH = 100

    class << self
      extend T::Sig

      # Maximum nesting depth for objects and arrays. Raise ParseError when exceeded.
      sig { returns(Integer) }
      attr_accessor :max_depth

      # Parse a complete agtype string and return the typed Ruby value.
      # Returns nil for empty/nil input.
      sig { params(input: T.nilable(String)).returns(T.untyped) }
      def parse(input)
        return nil if input.nil?

        stripped = input.strip
        return nil if stripped.empty?

        parser = new(stripped)
        result = parser.parse_agtype
        parser.expect_eof
        result
      end
    end

    @max_depth = T.let(DEFAULT_MAX_DEPTH, Integer)

    sig { params(input: String).void }
    def initialize(input)
      @input = input
      @pos = T.let(0, Integer)
      @depth = T.let(0, Integer)
    end

    sig { returns(T.untyped) }
    def parse_agtype
      parse_ag_value
    end

    sig { returns(T.untyped) }
    def parse_ag_value
      value = parse_value
      if peek_annotation?
        annotation = parse_type_annotation
        apply_annotation(annotation, value)
      else
        value
      end
    end

    sig { returns(T.untyped) }
    def parse_value
      skip_whitespace

      c = peek
      raise ParseError, "Unexpected character at position #{@pos}: #{c.inspect}" unless c

      if c == '"'
        parse_string
      elsif c == '{'
        parse_object
      elsif c == '['
        parse_array
      elsif c == 'n'
        parse_keyword('null', nil)
      elsif c == 't'
        parse_keyword('true', true)
      elsif c == 'f'
        parse_keyword('false', false)
      elsif c == 'N'
        parse_keyword('NaN', Float::NAN)
      elsif c == 'I'
        parse_keyword('Infinity', Float::INFINITY)
      elsif c == '-'
        # Could be -Infinity, a negative number, or negative zero
        if @input[@pos, 10] == '-Infinity' && !ident_char?(@input[@pos + 10])
          @pos += 10
          -Float::INFINITY
        else
          parse_number
        end
      elsif digit?(c)
        parse_number
      else
        raise ParseError, "Unexpected character at position #{@pos}: #{c.inspect}"
      end
    end

    sig { returns(String) }
    def parse_string
      advance # consume opening "
      buf = +''
      while peek && peek != '"'
        if peek == '\\'
          buf << parse_escape_sequence
        else
          buf << advance
        end
      end
      advance # consume closing "
      buf
    end

    sig { returns(T.untyped) }
    def parse_number
      # Collect the number text
      num_text = +''
      has_leading_zero = false

      # RATIONALE: After consuming '-', we must see at least one digit.
      # The old code silently produced 0 for bare '-' with no digit following.
      if peek == '-'
        num_text << advance
        raise ParseError, "Expected digit after '-' at position #{@pos}" unless peek && digit?(peek)
      end

      # Integer part — Agtype.g4: '0' | [1-9][0-9]*
      if peek == '0'
        num_text << advance
        # Leading zero is only valid if followed by '.', 'e'/'E', or end/non-digit
        if peek && digit?(peek)
          has_leading_zero = true
          while peek && digit?(peek)
            num_text << advance
          end
        end
      elsif digit?(peek)
        num_text << advance
        while peek && digit?(peek)
          num_text << advance
        end
      end

      # Decimal part
      has_decimal = false
      if peek == '.'
        has_decimal = true
        num_text << advance
        while peek && digit?(peek)
          num_text << advance
        end
      end

      # Exponent part
      has_exponent = false
      if peek && (peek == 'e' || peek == 'E')
        has_exponent = true
        num_text << advance
        num_text << advance if peek && (peek == '+' || peek == '-')
        while peek && digit?(peek)
          num_text << advance
        end
      end

      # Reject leading zeros per Agtype.g4 (e.g., "007" is invalid)
      if has_leading_zero
        raise ParseError, "Leading zeros not allowed in agtype integer at position #{@pos}: #{num_text}"
      end

      if has_decimal || has_exponent
        num_text.to_f
      else
        num_text.to_i
      end
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def parse_object
      check_depth
      advance # consume {
      skip_whitespace

      obj = {}
      if peek != '}'
        key, value = parse_pair
        obj[key] = value
        skip_whitespace
        while peek == ','
          advance
          skip_whitespace
          key, value = parse_pair
          obj[key] = value
          skip_whitespace
        end
      end

      advance # consume }
      @depth -= 1
      obj
    end

    sig { returns([String, T.untyped]) }
    def parse_pair
      skip_whitespace
      key = parse_string
      skip_whitespace
      advance # consume :
      skip_whitespace
      value = parse_ag_value
      [key, value]
    end

    sig { returns(T::Array[T.untyped]) }
    def parse_array
      check_depth
      advance # consume [
      skip_whitespace

      arr = []
      if peek != ']'
        arr << parse_ag_value
        skip_whitespace
        while peek == ','
          advance
          skip_whitespace
          arr << parse_ag_value
          skip_whitespace
        end
      end

      advance # consume ]
      @depth -= 1
      arr
    end

    sig { returns(String) }
    def parse_type_annotation
      advance # first :
      advance # second :
      ident = +''
      while peek && (ident_char?(peek))
        ident << advance
      end
      raise ParseError, "Empty type annotation at position #{@pos}" if ident.empty?

      ident
    end

    sig { void }
    def expect_eof
      skip_whitespace
      return if @pos >= @input.length

      raise ParseError, "Unexpected trailing content at position #{@pos}: #{@input[@pos..].inspect}"
    end

    private

    sig { void }
    def check_depth
      @depth += 1
      if @depth > self.class.max_depth
        raise ParseError, "Nesting depth exceeds #{self.class.max_depth} at position #{@pos}"
      end
    end

    # Parse a keyword (null, true, false, NaN, Infinity) with boundary check.
    # Ensures the keyword is not a prefix of a longer identifier.
    sig { params(keyword: String, value: T.untyped).returns(T.untyped) }
    def parse_keyword(keyword, value)
      end_pos = @pos + keyword.length
      # Keyword boundary: next char must not be an identifier character
      if end_pos < @input.length && ident_char?(@input[end_pos])
        raise ParseError, "Unexpected identifier at position #{@pos}: expected '#{keyword}' but got longer token"
      end
      @pos = end_pos
      value
    end

    sig { params(annotation: String, value: T.untyped).returns(T.untyped) }
    def apply_annotation(annotation, value)
      case annotation
      when 'numeric'
        BigDecimal(value.to_s)
      when 'vertex'
        raise ParseError, "Expected Hash for ::vertex, got #{value.class}" unless value.is_a?(Hash)
        # RATIONALE: Field names derived from Vertex::FIELDS rather than
        # hardcoded, so adding a field to Vertex is a single-site change.
        kwargs = Vertex::FIELDS.each_with_object({}) do |f, h|
          h[f] = f == :properties ? (value[f.to_s] || {}) : value[f.to_s]
        end
        Vertex.new(**T.unsafe(kwargs))
      when 'edge'
        raise ParseError, "Expected Hash for ::edge, got #{value.class}" unless value.is_a?(Hash)
        kwargs = Edge::FIELDS.each_with_object({}) do |f, h|
          h[f] = f == :properties ? (value[f.to_s] || {}) : value[f.to_s]
        end
        Edge.new(**T.unsafe(kwargs))
      when 'path'
        raise ParseError, "Expected Array for ::path, got #{value.class}" unless value.is_a?(Array)
        Path.new(entities: value)
      else
        value
      end
    end

    sig { returns(T::Boolean) }
    def peek_annotation?
      saved = @pos
      skip_whitespace
      result = peek == ':' && @pos + 1 < @input.length && @input[@pos + 1] == ':'
      @pos = saved
      result
    end

    sig { returns(String) }
    def parse_escape_sequence
      advance # consume backslash
      c = advance
      case c
      when '"', '\\', '/' then c
      when 'b'  then "\b"
      when 'f'  then "\f"
      when 'n'  then "\n"
      when 'r'  then "\r"
      when 't'  then "\t"
      when 'u'
        codepoint = parse_unicode_escape
        # Handle UTF-16 surrogate pairs: if high surrogate, expect low surrogate
        if codepoint >= 0xD800 && codepoint <= 0xDBFF
          # High surrogate — next must be \uXXXX low surrogate
          if peek == '\\' && @input[@pos + 1] == 'u'
            advance # consume backslash
            advance # consume 'u'
            low = parse_unicode_escape
            raise ParseError, "Invalid surrogate pair: expected low surrogate after high surrogate" unless low >= 0xDC00 && low <= 0xDFFF
            codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00)
          else
            raise ParseError, "High surrogate \\u#{format('%04X', codepoint)} without following low surrogate"
          end
        elsif codepoint >= 0xDC00 && codepoint <= 0xDFFF
          raise ParseError, "Low surrogate \\u#{format('%04X', codepoint)} without preceding high surrogate"
        end
        codepoint.chr(Encoding::UTF_8)
      else
        "\\#{c}"
      end
    end

    # Parse 4 hex digits after \u and return the integer codepoint.
    sig { returns(Integer) }
    def parse_unicode_escape
      hex = @input[@pos, 4]
      raise ParseError, "Incomplete unicode escape at position #{@pos}" unless hex && hex.length == 4
      @pos += 4
      hex.to_i(16)
    end

    # --- Low-level character operations ---

    sig { returns(T.nilable(String)) }
    def peek
      @pos < @input.length ? @input[@pos] : nil
    end

    # Advance one character and return it.
    sig { returns(String) }
    def advance
      raise ParseError, "Unexpected end of input at position #{@pos}" unless @pos < @input.length

      c = @input[@pos]
      @pos += 1
      T.must(c)
    end

    sig { void }
    def skip_whitespace
      while @pos < @input.length && (@input[@pos] == ' ' || @input[@pos] == "\t" || @input[@pos] == "\n" || @input[@pos] == "\r")
        @pos += 1
      end
    end

    sig { params(c: T.nilable(String)).returns(T::Boolean) }
    def digit?(c)
      return false if c.nil?
      c >= '0' && c <= '9'
    end

    # RATIONALE: alnum? was dead code — replaced by ident_char? which also
    # covers underscores. Kept as alias for backward compat with any external
    # subclasses, but all internal callers use ident_char?.
    sig { params(c: T.nilable(String)).returns(T::Boolean) }
    def alnum?(c)
      ident_char?(c)
    end

    # Is this character valid in an identifier? (Used for keyword boundary checks)
    sig { params(c: T.nilable(String)).returns(T::Boolean) }
    def ident_char?(c)
      return false if c.nil?
      (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
    end
  end
end
