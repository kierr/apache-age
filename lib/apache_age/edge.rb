# typed: strong
# frozen_string_literal: true

module ApacheAge
  # Generic AGE edge (relationship) model. Returned by AgtypeParser when a
  # ::edge type annotation is encountered, and by query_cypher when
  # the result column contains edge agtype values.
  #
  # Matches the Edge model from the official Python, Go, JDBC, and
  # Node.js drivers: {id, label, start_id, end_id, properties}.
  class Edge
    extend T::Sig

    sig { returns(T.nilable(Integer)) }
    attr_reader :id

    sig { returns(T.nilable(String)) }
    attr_reader :label

    sig { returns(T.nilable(Integer)) }
    attr_reader :start_id

    sig { returns(T.nilable(Integer)) }
    attr_reader :end_id

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :properties

    sig do
      params(
        id: T.nilable(Integer),
        label: T.nilable(String),
        start_id: T.nilable(Integer),
        end_id: T.nilable(Integer),
        properties: T::Hash[String, T.untyped]
      ).void
    end
    def initialize(id:, label: nil, start_id: nil, end_id: nil, properties: {})
      @id = id
      @label = label
      @start_id = start_id
      @end_id = end_id
      @properties = properties
    end

    sig { returns(String) }
    def to_s
      "{label:#{@label}, id:#{@id}, start_id:#{@start_id}, end_id:#{@end_id}, properties:#{@properties}}::EDGE"
    end

    sig { returns(String) }
    def inspect
      "#<ApacheAge::Edge id=#{@id} label=#{@label.inspect} start_id=#{@start_id} end_id=#{@end_id}>"
    end

    # Bracket access for backward compatibility with Hash-based call sites.
    sig { params(key: Symbol).returns(T.untyped) }
    def [](key)
      case key
      when :id then @id
      when :label then @label
      when :start_id then @start_id
      when :end_id then @end_id
      when :properties then @properties
      end
    end
  end
end
