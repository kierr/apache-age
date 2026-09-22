# typed: strict
# frozen_string_literal: true

module ApacheAge
  # Typed representation of an AGE graph traversal result (vertex identity).
  # Returned by ApacheAge.traverse and ApacheAge.traverse_batch instead of
  # untyped hashes, confining T.untyped to the AGE parsing layer.
  #
  # Supports bracket access ([].[]) for backward compatibility with call sites
  # that previously received Hash results.
  class TraverseResult
    extend T::Sig

    sig { returns(String) }
    attr_reader :entity_id

    sig { returns(String) }
    attr_reader :object_type

    sig { params(entity_id: String, object_type: String).void }
    def initialize(entity_id:, object_type:)
      @entity_id = entity_id
      @object_type = object_type
    end

    # RATIONALE: object_id shadows Ruby's Object#object_id — using entity_id instead.
    # Bracket access preserves backward compatibility with call sites expecting Hash keys.
    sig { params(key: Symbol).returns(T.untyped) }
    def [](key)
      case key
      when :object_id, :entity_id then @entity_id
      when :object_type then @object_type
      end
    end
  end
end
