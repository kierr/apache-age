# typed: strong
# frozen_string_literal: true

module ApacheAge
  # Generic AGE vertex (node) model. Returned by AgtypeParser when a
  # ::vertex type annotation is encountered, and by query_cypher when
  # the result column contains vertex agtype values.
  #
  # Matches the Vertex model from the official Python, Go, JDBC, and
  # Node.js drivers: {id, label, properties}.
  class Vertex
    extend T::Sig

    sig { returns(T.nilable(Integer)) }
    attr_reader :id

    sig { returns(T.nilable(String)) }
    attr_reader :label

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :properties

    sig do
      params(
        id: T.nilable(Integer),
        label: T.nilable(String),
        properties: T::Hash[String, T.untyped]
      ).void
    end
    def initialize(id:, label: nil, properties: {})
      @id = id
      @label = label
      @properties = properties
    end

    sig { returns(String) }
    def to_s
      "{label:#{@label}, id:#{@id}, properties:#{@properties}}::VERTEX"
    end

    sig { returns(String) }
    def inspect
      "#<ApacheAge::Vertex id=#{@id} label=#{@label.inspect}>"
    end

    # Bracket access — accepts Symbol or String for ergonomic use.
    sig { params(key: T.any(Symbol, String)).returns(T.untyped) }
    def [](key)
      case key.to_s
      when 'id' then @id
      when 'label' then @label
      when 'properties' then @properties
      else @properties[key.to_s]
      end
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def to_h
      { 'id' => @id, 'label' => @label, 'properties' => @properties }
    end
  end
end
