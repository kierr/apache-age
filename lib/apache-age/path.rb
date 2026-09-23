# typed: strict
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

    # RATIONALE: Cache vertex/edge arrays on construction so length and
    # vertices/edges are O(1) instead of O(n) scans on every call.
    sig { params(entities: T::Array[T.any(Vertex, Edge)]).void }
    def initialize(entities: [])
      @entities = entities
      @vertices = T.let(entities.grep(Vertex), T::Array[Vertex])
      @edges = T.let(entities.grep(Edge), T::Array[Edge])
    end

    sig { returns(T::Array[Vertex]) }
    attr_reader :vertices

    sig { returns(T::Array[Edge]) }
    attr_reader :edges

    sig { returns(Integer) }
    def length
      @edges.length
    end

    sig { returns(String) }
    def to_s
      "[#{@entities.join(', ')}]::PATH"
    end

    sig { returns(String) }
    def inspect
      "#<ApacheAge::Path length=#{length} vertices=#{@vertices.length} edges=#{@edges.length}>"
    end

    # Produce valid agtype for this path, suitable for embedding in
    # Cypher parameters or serializing back to AGE.
    sig { returns(String) }
    def to_agtype
      enc = @entities.map(&:to_agtype).join(', ')
      "[#{enc}]::path"
    end
  end
end
