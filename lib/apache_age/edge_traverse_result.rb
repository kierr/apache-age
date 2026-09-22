# typed: strict
# frozen_string_literal: true

module ApacheAge
  # Typed representation of an AGE edge traversal result (target vertex + edge properties).
  # Returned by ApacheAge.traverse_edges instead of untyped hashes.
  #
  # Supports bracket access ([].[]) for backward compatibility with call sites
  # that previously received Hash results.
  class EdgeTraverseResult
    extend T::Sig

    sig { returns(String) }
    attr_reader :entity_id

    sig { returns(String) }
    attr_reader :object_type

    sig { returns(EdgeProperties) }
    attr_reader :properties

    sig { params(entity_id: String, object_type: String, properties: EdgeProperties).void }
    def initialize(entity_id:, object_type:, properties:)
      @entity_id = entity_id
      @object_type = object_type
      @properties = properties
    end

    # RATIONALE: object_id shadows Ruby's Object#object_id — using entity_id instead.
    sig { params(key: Symbol).returns(T.untyped) }
    def [](key)
      case key
      when :object_id, :entity_id then @entity_id
      when :object_type then @object_type
      when :properties then @properties
      end
    end
  end
end
