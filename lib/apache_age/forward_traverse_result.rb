# typed: strict
# frozen_string_literal: true

module ApacheAge
  # Typed representation of an AGE forward-traversal result (source→target identity).
  # Returned by ApacheAge.forward_traverse_batch: given a set of source object_ids,
  # each edge is attributed back to its source together with the target identity.
  #
  # Supports bracket access ([].[]) for backward compatibility with call sites
  # that previously received Hash results.
  #
  # RATIONALE: DYNAMIC-BOUNDARY: ApacheAge::ForwardTraverseResult#[] returns T.untyped because bracket-access callers dispatch dynamically on the Symbol key; the return is narrowed by each caller via the known case branch. T.untyped is the boundary type at the bracket-access shim. Would need a typed HashLike[T] protocol or removal of the legacy bracket-access shim to drop.
  class ForwardTraverseResult
    extend T::Sig

    sig { returns(String) }
    attr_reader :source_object_id

    sig { returns(String) }
    attr_reader :target_object_id

    sig { returns(String) }
    attr_reader :target_object_type

    sig { params(source_object_id: String, target_object_id: String, target_object_type: String).void }
    def initialize(source_object_id:, target_object_id:, target_object_type:)
      @source_object_id = source_object_id
      @target_object_id = target_object_id
      @target_object_type = target_object_type
    end

    sig { params(key: Symbol).returns(T.untyped) }
    def [](key)
      case key
      when :source_object_id then @source_object_id
      when :target_object_id then @target_object_id
      when :target_object_type then @target_object_type
      end
    end
  end
end
