# typed: strong
# frozen_string_literal: true

module ApacheAge
  # Typed representation of AGE edge properties (confidence, temporal metadata).
  # Extracted from traverse_edges results instead of flowing as T.untyped hashes.
  #
  # Supports bracket access ([].[]) for backward compatibility with call sites
  # that previously received Hash results.
  #
  # RATIONALE: DYNAMIC-BOUNDARY: ApacheAge::EdgeProperties#[] returns T.untyped because bracket-access callers (legacy call sites that previously received Hash) dispatch dynamically on the Symbol key; the return is narrowed by each caller via the known case branch. T.untyped is the boundary type at the bracket-access shim. Would need a typed HashLike[T] protocol or removal of the legacy bracket-access shim to drop.
  class EdgeProperties
    extend T::Sig

    # Confidence is Numeric (not just Float) because AgtypeParser returns
    # Integer for whole numbers, BigDecimal for ::numeric, and Float for
    # decimal values. Callers that need Float should use .to_f.
    sig { returns(T.nilable(Numeric)) }
    attr_reader :confidence

    sig { returns(T.nilable(String)) }
    attr_reader :first_seen

    sig { returns(T.nilable(String)) }
    attr_reader :last_seen

    sig { params(confidence: T.nilable(Numeric), first_seen: T.nilable(String), last_seen: T.nilable(String)).void }
    def initialize(confidence: nil, first_seen: nil, last_seen: nil)
      @confidence = confidence
      @first_seen = first_seen
      @last_seen = last_seen
    end

    sig { params(key: Symbol).returns(T.untyped) }
    def [](key)
      case key
      when :confidence then @confidence
      when :first_seen then @first_seen
      when :last_seen then @last_seen
      end
    end
  end
end
