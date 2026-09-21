# typed: strong
# frozen_string_literal: true

module ApacheAge
  # Generic AGE path model. Returned by AgtypeParser when a ::path type
  # annotation is encountered, and by query_cypher when the result column
  # contains path agtype values.
  #
  # A path is an alternating sequence: [Vertex, Edge, Vertex, Edge, ..., Vertex].
  # Matches the Path model from the official Go and Python drivers.
  class Path
    extend T::Sig

    sig { returns(T::Array[T.any(Vertex, Edge)]) }
    attr_reader :entities

    sig { params(entities: T::Array[T.any(Vertex, Edge)]).void }
    def initialize(entities: [])
      @entities = entities
    end

    # Extract only the vertices from the path.
    sig { returns(T::Array[Vertex]) }
    def vertices
      @entities.select { |e| e.is_a?(Vertex) }
    end

    # Extract only the edges from the path.
    sig { returns(T::Array[Edge]) }
    def edges
      @entities.select { |e| e.is_a?(Edge) }
    end

    sig { returns(Integer) }
    def length
      edges.length
    end

    sig { returns(String) }
    def to_s
      "[#{@entities.map(&:to_s).join(', ')}]::PATH"
    end

    sig { returns(String) }
    def inspect
      "#<ApacheAge::Path length=#{length} vertices=#{vertices.length} edges=#{edges.length}>"
    end
  end
end
