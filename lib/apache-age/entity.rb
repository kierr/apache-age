# typed: strict
# frozen_string_literal: true

# Opt-in entity layer for Apache AGE: the object_id/object_type vertex model,
# entity CRUD, traversal, and typed results. Load with `require 'apache-age/entity'`.
# Without this require, only the driver core (graph lifecycle, query_cypher, agtype)
# is available — matching the official AGE driver API.
#
# Reopens module ApacheAge (same namespace as the driver core) and adds singleton
# methods via class << self, so ApacheAge.create_vertex resolves after the require.

require 'apache-age/edge_properties'
require 'apache-age/traverse_result'
require 'apache-age/edge_traverse_result'
require 'apache-age/forward_traverse_result'
require 'apache-age/reverse_traverse_result'

module ApacheAge
  class << self
    extend T::Sig

    # --- Core CRUD API ---

    sig { params(object_id: String, object_type: String).returns(T::Boolean) }
    def create_vertex(object_id:, object_type:)
      return false unless graph_available?

      validate_object_id!(object_id)
      validate_object_type!(object_type)

      # RATIONALE: Vertices are matched by {object_id} alone across every query
      # path (vertex_exists?, delete_vertex, build_edge_cypher, build_traverse_cypher)
      # — none use a label in their MATCH pattern. Storing object_type as a property
      # (and NOT as a label) keeps create_vertex consistent with those paths: the
      # same MERGE finds the vertex later, instead of creating a duplicate under a
      # different label. object_type is still queryable as `target.object_type`.
      # Would need a typed-label scheme where EVERY path (including edge/traverse)
      # passed from_type/to_type to switch back to label-by-type.
      cypher = <<~CYPHER
        MERGE (v {object_id: '#{cypher_escape(object_id)}', object_type: '#{cypher_escape(object_type)}'})
        RETURN 1 AS result
      CYPHER
      execute_cypher(cypher)
      true
    rescue StandardError => e
      log(:error, 'age_graph.create_vertex_failed', error_class: e.class.name, error_message: e.message,
                                                    backtrace: e.backtrace&.first(5))
      false
    end

    sig do
      params(
        from_object_id: String, to_object_id: String,
        label: String, properties: T::Hash[Symbol, T.untyped],
        directionality: Symbol
      ).returns(T::Boolean)
    end
    def create_edge(from_object_id, to_object_id, label, properties: {}, directionality: :directed)
      return false unless graph_available?

      validate_label!(label)
      cypher = build_edge_cypher(from_object_id, to_object_id, label, properties, directionality)
      execute_cypher(cypher)
      true
    rescue EdgeCreationError => e
      log(:warn, 'age_graph.edge_creation_failed', error_class: e.class.name, error_message: e.message)
      false
    rescue StandardError => e
      log(:error, 'age_graph.create_edge_failed', error_class: e.class.name, error_message: e.message,
                                                  backtrace: e.backtrace&.first(5))
      false
    end

    sig { params(object_id: String, edge_label: String, direction: Symbol).returns(T::Array[TraverseResult]) }
    def traverse(object_id, edge_label, direction: :outgoing)
      return [] unless graph_available?

      validate_label!(edge_label)
      cypher = build_traverse_cypher([object_id], edge_label, direction)
      result = execute_cypher_with_columns(cypher, columns: traverse_columns)
      parse_traverse_results(result)
    rescue StandardError => e
      log(:error, 'age_graph.traverse_failed', error_class: e.class.name, error_message: e.message)
      []
    end

    sig { params(object_ids: T::Array[String], edge_label: String, direction: Symbol).returns(T::Array[TraverseResult]) }
    def traverse_batch(object_ids, edge_label, direction: :outgoing)
      return [] unless graph_available?
      return [] if object_ids.empty?

      validate_label!(edge_label)
      object_ids.each_slice(500).flat_map do |batch|
        cypher = build_traverse_cypher(batch, edge_label, direction)
        result = execute_cypher_with_columns(cypher, columns: traverse_columns)
        parse_traverse_results(result)
      end
    rescue StandardError => e
      log(:error, 'age_graph.traverse_batch_failed', error_class: e.class.name, error_message: e.message)
      []
    end

    sig { params(target_object_ids: T::Array[String], edge_label: String).returns(T::Array[ReverseTraverseResult]) }
    def reverse_traverse_batch(target_object_ids, edge_label)
      return [] unless graph_available?
      return [] if target_object_ids.empty?

      validate_label!(edge_label)
      target_object_ids.each_slice(500).flat_map do |batch|
        cypher = <<~CYPHER
          MATCH (source)-[e:#{edge_label}]->(target)
          WHERE target.object_id IN [#{batch.map { |id| "'#{cypher_escape(id)}'" }.join(', ')}]
          RETURN source.object_id AS source_object_id,
                 target.object_id AS target_object_id,
                 source.object_type AS source_object_type
        CYPHER
        result = execute_cypher_with_columns(cypher)
        parse_reverse_traverse_results(result)
      end
    rescue StandardError => e
      log(:error, 'age_graph.reverse_traverse_batch_failed', error_class: e.class.name, error_message: e.message)
      []
    end

    sig { params(object_id: String, edge_label: String, direction: Symbol).returns(T::Array[EdgeTraverseResult]) }
    def traverse_edges(object_id, edge_label, direction: :outgoing)
      return [] unless graph_available?

      validate_label!(edge_label)
      cypher = build_traverse_edges_cypher(object_id, edge_label, direction)
      result = execute_cypher_with_columns(cypher)
      parse_edge_traverse_results(result)
    rescue StandardError => e
      log(:error, 'age_graph.traverse_edges_failed', error_class: e.class.name, error_message: e.message)
      []
    end

    sig { params(source_object_ids: T::Array[String], edge_label: String).returns(T::Array[ForwardTraverseResult]) }
    def forward_traverse_batch(source_object_ids, edge_label)
      return [] unless graph_available?
      return [] if source_object_ids.empty?

      validate_label!(edge_label)
      source_object_ids.each_slice(500).flat_map do |batch|
        cypher = <<~CYPHER
          MATCH (source)-[e:#{edge_label}]->(target)
          WHERE source.object_id IN [#{batch.map { |id| "'#{cypher_escape(id)}'" }.join(', ')}]
          RETURN source.object_id AS source_object_id,
                 target.object_id AS target_object_id,
                 target.object_type AS target_object_type
        CYPHER
        result = execute_cypher_with_columns(cypher)
        parse_forward_traverse_results(result)
      end
    rescue StandardError => e
      log(:error, 'age_graph.forward_traverse_batch_failed', error_class: e.class.name, error_message: e.message)
      []
    end

    sig { params(object_id: T.nilable(T.any(String, Integer))).returns(T::Boolean) }
    def vertex_exists?(object_id:)
      return false if object_id.nil?

      oid = validate_object_id!(object_id)
      return false unless graph_available?

      cypher = "MATCH (v {object_id: '#{cypher_escape(oid)}'}) RETURN count(v) AS result"
      result = execute_cypher(cypher)
      row = T.cast(result, T::Array[T::Hash[String, T.untyped]]).first
      cnt = parse_agtype_numeric(row&.fetch('result', row.fetch('cnt', nil)))
      cnt ? cnt.to_i.positive? : false
    rescue StandardError
      false
    end

    sig { params(from_object_id: String, to_object_id: String, label: String).returns(T::Boolean) }
    def edge_exists?(from_object_id, to_object_id, label)
      return false unless graph_available?

      validate_label!(label)
      cypher = "MATCH (a {object_id: '#{cypher_escape(from_object_id)}'})-[e:#{label}]->(b {object_id: '#{cypher_escape(to_object_id)}'}) RETURN count(e) AS result"
      result = execute_cypher(cypher)
      row = T.cast(result, T::Array[T::Hash[String, T.untyped]]).first
      cnt = parse_agtype_numeric(row&.fetch('result', row.fetch('cnt', nil)))
      cnt ? cnt.to_i.positive? : false
    rescue StandardError
      false
    end

    sig { params(object_id: T.any(String, Integer)).returns(T::Boolean) }
    def delete_vertex(object_id)
      return false unless graph_available?

      oid = validate_object_id!(object_id)
      cypher = "MATCH (v {object_id: '#{cypher_escape(oid)}'}) DETACH DELETE v RETURN 1 AS result"
      execute_cypher(cypher)
      true
    rescue StandardError => e
      log(:error, 'age_graph.delete_vertex_failed', error_class: e.class.name, error_message: e.message)
      false
    end

    sig { params(from_object_id: String, to_object_id: String, label: String).returns(T::Boolean) }
    def delete_edge(from_object_id, to_object_id, label)
      return false unless graph_available?

      validate_label!(label)
      cypher = "MATCH (a {object_id: '#{cypher_escape(from_object_id)}'})-[e:#{label}]->(b {object_id: '#{cypher_escape(to_object_id)}'}) DELETE e RETURN 1 AS result"
      execute_cypher(cypher)
      true
    rescue StandardError => e
      log(:error, 'age_graph.delete_edge_failed', error_class: e.class.name, error_message: e.message)
      false
    end

    # --- Entity-specific validation ---

    sig { params(object_id: T.untyped).returns(String) }
    def validate_object_id!(object_id)
      id = object_id.to_s
      return id if id.match?(VALID_OBJECT_ID)

      Kernel.raise ArgumentError, "Invalid AGE object_id '#{id}'"
    end

    sig { params(object_type: T.untyped).returns(String) }
    def validate_object_type!(object_type)
      type = object_type.to_s
      return type if type.match?(VALID_OBJECT_TYPE)

      Kernel.raise ArgumentError, "Invalid AGE object_type '#{type}'"
    end

    # --- Cypher builders ---

    sig do
      params(
        from_id: String, to_id: String, label: String,
        properties: T::Hash[Symbol, T.untyped],
        directionality: Symbol
      ).returns(String)
    end
    def build_edge_cypher(from_id, to_id, label, properties, directionality)
      props_clause = build_properties_clause(properties)
      set_clause = properties.empty? ? '' : " SET e += #{props_clause}"
      set2_clause = properties.empty? ? '' : " SET e2 += #{props_clause}"
      # RATIONALE: Match by {object_id} with no label, matching create_vertex's
      # MERGE pattern. The prior `:Entity` label created DUPLICATE vertices when
      # the source had been created by create_vertex (which labeled by object_type):
      # MERGE (a:Entity {...}) cannot find a vertex labeled `:person`, so it made
      # a new one. Label-less match finds the existing vertex regardless of label.
      # Would need from_type/to_type params to use typed labels consistently.
      # directionality: :undirected creates both directions (pre-extraction semantics).
      if directionality == :undirected
        <<~CYPHER
          MATCH (a {object_id: '#{cypher_escape(from_id)}'}), (b {object_id: '#{cypher_escape(to_id)}'})
          MERGE (a)-[e:#{label}]->(b)#{set_clause}
          MERGE (b)-[e2:#{label}]->(a)#{set2_clause}
          RETURN 1 AS result
        CYPHER
      else
        <<~CYPHER
          MATCH (a {object_id: '#{cypher_escape(from_id)}'}), (b {object_id: '#{cypher_escape(to_id)}'})
          MERGE (a)-[e:#{label}]->(b)#{set_clause}
          RETURN 1 AS result
        CYPHER
      end
    end

    sig { params(object_ids: T::Array[String], edge_label: String, direction: Symbol).returns(String) }
    def build_traverse_cypher(object_ids, edge_label, direction)
      dir_match = case direction
                  when :outgoing then '-[e:%s]->'
                  when :incoming then '<-[e:%s]-'
                  else '-[e:%s]-'
                  end
      if object_ids.length == 1
        <<~CYPHER
          MATCH (source {object_id: '#{cypher_escape(T.must(object_ids.first))}'})#{format(dir_match, edge_label)}(target)
          RETURN target.object_id AS object_id, target.object_type AS object_type
        CYPHER
      else
        <<~CYPHER
          MATCH (source)-#{format(dir_match, edge_label)}(target)
          WHERE source.object_id IN [#{object_ids.map { |id| "'#{cypher_escape(id)}'" }.join(', ')}]
          RETURN target.object_id AS object_id, target.object_type AS object_type
        CYPHER
      end
    end

    sig { params(object_id: String, edge_label: String, direction: Symbol).returns(String) }
    def build_traverse_edges_cypher(object_id, edge_label, direction)
      dir_match = case direction
                  when :outgoing then '-[e:%s]->'
                  when :incoming then '<-[e:%s]-'
                  else '-[e:%s]-'
                  end
      <<~CYPHER
        MATCH (source {object_id: '#{cypher_escape(object_id)}'})#{format(dir_match, edge_label)}(target)
        RETURN target.object_id AS object_id,
               target.object_type AS object_type,
               e.confidence AS confidence,
               e.first_seen AS first_seen,
               e.last_seen AS last_seen
      CYPHER
    end

    sig { returns(String) }
    def traverse_columns
      'object_id ag_catalog.agtype, object_type ag_catalog.agtype'
    end

    sig { params(properties: T::Hash[Symbol, T.untyped]).returns(String) }
    def build_properties_clause(properties)
      return '' if properties.empty?

      parts = properties.filter_map do |key, value|
        next if value.nil?

        Kernel.raise ArgumentError, "Invalid property key '#{key}'" unless key.to_s.match?(VALID_PROPERTY_KEY)
        unless value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(TrueClass) || value.is_a?(FalseClass)
          Kernel.raise ArgumentError,
                       "Unsupported property value type '#{value.class}'"
        end

        val = case value
              when String then "'#{cypher_escape(value)}'"
              when TrueClass, FalseClass then value.to_s
              else value.to_f == value.to_i ? value.to_i.to_s : value.to_f.to_s
              end
        "#{key}: #{val}"
      end
      " {#{parts.join(', ')}}"
    end

    # --- Multi-hop BFS traversal ---

    # Iterative breadth-first traversal up to max_depth hops. Returns one
    # entry per reachable object_id with the hop depth and direction at which it
    # was first reached. Deduplicates across hops via a visited set so graph
    # cycles cannot cause unbounded work. direction :both runs outgoing and
    # incoming and merges them (AGE emits one arrow shape per query, so the
    # union is taken in Ruby). Each entry is a Hash with :object_id,
    # :object_type, :depth, :direction (direction is a string).
    sig do
      params(
        start_object_id: String, edge_label: String,
        direction: Symbol, max_depth: Integer
      ).returns(T::Array[T::Hash[Symbol, T.untyped]])
    end
    def traverse_multihop(start_object_id, edge_label, direction:, max_depth:)
      if direction == :both
        outgoing = run_multihop(start_object_id, edge_label, :outgoing, max_depth)
        incoming = run_multihop(start_object_id, edge_label, :incoming, max_depth)
        merge_both_directions(outgoing, incoming)
      else
        run_multihop(start_object_id, edge_label, direction, max_depth)
      end
    end

    sig { params(start_object_id: String, edge_label: String, direction: Symbol, max_depth: Integer).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def run_multihop(start_object_id, edge_label, direction, max_depth)
      visited = T.let(Set.new([start_object_id]), T::Set[String])
      frontier = T.let([start_object_id], T::Array[String])
      results = T.let([], T::Array[T::Hash[Symbol, T.untyped]])

      max_depth.times do |depth_i|
        depth = depth_i + 1
        break if frontier.empty?

        batch = traverse_batch(frontier, edge_label, direction: direction)
        frontier = expand_frontier(batch, visited, depth, direction, results)
      end

      results
    end

    sig do
      params(
        batch: T::Array[T.untyped],
        visited: T::Set[String],
        depth: Integer,
        direction: Symbol,
        results: T::Array[T::Hash[Symbol, T.untyped]]
      ).returns(T::Array[String])
    end
    def expand_frontier(batch, visited, depth, direction, results)
      next_frontier = T.let([], T::Array[String])
      batch.each do |tr|
        result = T.cast(tr, ApacheAge::TraverseResult)
        next if visited.include?(result.entity_id)

        visited.add(result.entity_id)
        next_frontier << result.entity_id
        results.push(object_id: result.entity_id, object_type: result.object_type, depth: depth, direction: direction.to_s)
      end
      next_frontier
    end

    sig { params(outgoing: T::Array[T::Hash[Symbol, T.untyped]], incoming: T::Array[T::Hash[Symbol, T.untyped]]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def merge_both_directions(outgoing, incoming)
      by_oid = T.let({}, T::Hash[String, T::Hash[Symbol, T.untyped]])
      outgoing.each do |r|
        oid = T.cast(r[:object_id], String)
        by_oid[oid] = r
      end
      incoming.each do |r|
        oid = T.cast(r[:object_id], String)
        if by_oid.key?(oid)
          T.must(by_oid[oid])[:direction] = 'both'
        else
          by_oid[oid] = r
        end
      end
      by_oid.values
    end

    # --- Parsers ---

    sig { params(result: T.untyped).returns(T::Array[EdgeTraverseResult]) }
    def parse_edge_traverse_results(result)
      rows = T.cast(result, T::Array[T.untyped])
      rows.map do |row|
        hash = row.is_a?(Hash) ? row : T.cast(row, T::Hash[String, T.untyped])
        EdgeTraverseResult.new(
          entity_id: parse_agtype(hash['object_id']).to_s,
          object_type: parse_agtype(hash['object_type']).to_s,
          properties: EdgeProperties.new(
            confidence: parse_agtype_numeric(hash['confidence']),
            first_seen: parse_agtype(hash['first_seen']),
            last_seen: parse_agtype(hash['last_seen'])
          )
        )
      end
    end

    sig { params(result: T.untyped).returns(T::Array[TraverseResult]) }
    def parse_traverse_results(result)
      rows = T.cast(result, T::Array[T.untyped])
      rows.map do |row|
        hash = row.is_a?(Hash) ? row : T.cast(row, T::Hash[String, T.untyped])
        TraverseResult.new(
          entity_id: parse_agtype(hash['object_id']).to_s,
          object_type: parse_agtype(hash['object_type']).to_s
        )
      end
    end

    sig { params(result: T.untyped).returns(T::Array[ForwardTraverseResult]) }
    def parse_forward_traverse_results(result)
      rows = T.cast(result, T::Array[T.untyped])
      rows.map do |row|
        hash = row.is_a?(Hash) ? row : T.cast(row, T::Hash[String, T.untyped])
        ForwardTraverseResult.new(
          source_object_id: parse_agtype(hash['source_object_id']).to_s,
          target_object_id: parse_agtype(hash['target_object_id']).to_s,
          target_object_type: parse_agtype(hash['target_object_type']).to_s
        )
      end
    end

    sig { params(result: T.untyped).returns(T::Array[ReverseTraverseResult]) }
    def parse_reverse_traverse_results(result)
      rows = T.cast(result, T::Array[T.untyped])
      rows.map do |row|
        hash = row.is_a?(Hash) ? row : T.cast(row, T::Hash[String, T.untyped])
        ReverseTraverseResult.new(
          source_object_id: parse_agtype(hash['source_object_id']).to_s,
          target_object_id: parse_agtype(hash['target_object_id']).to_s,
          source_object_type: parse_agtype(hash['source_object_type']).to_s
        )
      end
    end

    private :validate_object_id!, :validate_object_type!,
            :build_edge_cypher, :build_traverse_cypher, :build_traverse_edges_cypher,
            :traverse_columns,
            :parse_edge_traverse_results, :parse_traverse_results,
            :parse_forward_traverse_results, :parse_reverse_traverse_results,
            :build_properties_clause,
            :run_multihop, :expand_frontier, :merge_both_directions
  end
end
