# typed: strict
# frozen_string_literal: true

require_relative 'test_helper'

class ApacheAgeVertexTest < Minitest::Test
  def test_vertex_valid
    v = ApacheAge::Vertex.new(id: 1, label: 'Person')
    assert_equal 1, v.id
    assert_equal 'Person', v.label
    assert_equal({}, v.properties)
  end

  def test_vertex_with_properties
    v = ApacheAge::Vertex.new(id: 1, label: 'Person', properties: { 'name' => 'Alice' })
    assert_equal({ 'name' => 'Alice' }, v.properties)
  end

  def test_vertex_missing_id_raises
    assert_raises(ArgumentError) { ApacheAge::Vertex.new(label: 'Person') }
  end

  def test_vertex_bracket_access_fields
    v = ApacheAge::Vertex.new(id: 1, label: 'Person', properties: { 'name' => 'Alice' })
    assert_equal 1, v[:id]
    assert_equal 'Person', v[:label]
    assert_equal({ 'name' => 'Alice' }, v[:properties])
    assert_nil v[:nonexistent]
  end

  def test_vertex_to_h
    v = ApacheAge::Vertex.new(id: 1, label: 'Person', properties: { 'name' => 'Alice' })
    h = v.to_h
    assert_equal 1, h[:id]
    assert_equal 'Person', h[:label]
    assert_equal({ 'name' => 'Alice' }, h[:properties])
  end

  def test_vertex_to_s_and_inspect
    v = ApacheAge::Vertex.new(id: 1, label: 'Person')
    assert_kind_of String, v.to_s
    assert_kind_of String, v.inspect
  end

  def test_vertex_to_agtype
    v = ApacheAge::Vertex.new(id: 1, label: 'Person', properties: { 'name' => 'A' })
    ag = v.to_agtype
    assert_includes ag, '1'
    assert_includes ag, 'Person'
    assert_includes ag, 'name'
  end
end

class ApacheAgeEdgeTest < Minitest::Test
  def test_edge_valid
    e = ApacheAge::Edge.new(id: 1, label: 'KNOWS', start_id: 100, end_id: 200)
    assert_equal 1, e.id
    assert_equal 'KNOWS', e.label
    assert_equal 100, e.start_id
    assert_equal 200, e.end_id
  end

  def test_edge_minimal
    e = ApacheAge::Edge.new(id: 1)
    assert_equal 1, e.id
    assert_nil e.label
    assert_nil e.start_id
    assert_nil e.end_id
  end

  def test_edge_missing_id_raises
    assert_raises(ArgumentError) { ApacheAge::Edge.new(label: 'KNOWS') }
  end

  def test_edge_bracket_access_fields
    e = ApacheAge::Edge.new(id: 1, label: 'KNOWS', start_id: 100, end_id: 200, properties: { 'w' => 2 })
    assert_equal 1, e[:id]
    assert_equal 'KNOWS', e[:label]
    assert_equal 100, e[:start_id]
    assert_equal 200, e[:end_id]
    assert_equal({ 'w' => 2 }, e[:properties])
    assert_nil e[:nonexistent]
  end

  def test_edge_to_h
    e = ApacheAge::Edge.new(id: 1, label: 'KNOWS', start_id: 100, end_id: 200)
    h = e.to_h
    assert_equal 1, h[:id]
    assert_equal 'KNOWS', h[:label]
    assert_equal 100, h[:start_id]
    assert_equal 200, h[:end_id]
  end

  def test_edge_to_s_and_inspect
    e = ApacheAge::Edge.new(id: 1, label: 'KNOWS')
    assert_kind_of String, e.to_s
    assert_kind_of String, e.inspect
  end

  def test_edge_to_agtype
    e = ApacheAge::Edge.new(id: 1, label: 'KNOWS', start_id: 100, end_id: 200)
    ag = e.to_agtype
    assert_includes ag, '1'
    assert_includes ag, 'KNOWS'
  end
end

class ApacheAgePathTest < Minitest::Test
  def test_path_empty
    p = ApacheAge::Path.new(entities: [])
    assert_equal [], p.edges
    assert_equal [], p.vertices
    assert_equal 0, p.length
  end

  def test_path_single_vertex
    v = ApacheAge::Vertex.new(id: 1, label: 'A')
    p = ApacheAge::Path.new(entities: [v])
    assert_equal [], p.edges
    assert_equal [v], p.vertices
    assert_equal 0, p.length
  end

  def test_path_with_edge
    v1 = ApacheAge::Vertex.new(id: 1, label: 'A')
    e = ApacheAge::Edge.new(id: 10, label: 'LINKS')
    v2 = ApacheAge::Vertex.new(id: 2, label: 'B')
    p = ApacheAge::Path.new(entities: [v1, e, v2])
    assert_equal [e], p.edges
    assert_equal [v1, v2], p.vertices
    assert_equal 1, p.length
  end

  def test_path_to_s_and_inspect
    v = ApacheAge::Vertex.new(id: 1, label: 'A')
    p = ApacheAge::Path.new(entities: [v])
    assert_kind_of String, p.to_s
    assert_kind_of String, p.inspect
  end

  def test_path_to_agtype
    v = ApacheAge::Vertex.new(id: 1, label: 'A')
    p = ApacheAge::Path.new(entities: [v])
    ag = p.to_agtype
    assert_includes ag, '1'
    assert_includes ag, 'A'
    assert_includes ag, 'path'
  end
end

class ApacheAgeEdgePropertiesTest < Minitest::Test
  def test_default_nil_values
    ep = ApacheAge::EdgeProperties.new
    assert_nil ep.confidence
    assert_nil ep.first_seen
    assert_nil ep.last_seen
  end

  def test_with_values
    ep = ApacheAge::EdgeProperties.new(confidence: 0.95, first_seen: '2024-01', last_seen: '2024-12')
    assert_equal 0.95, ep.confidence
    assert_equal '2024-01', ep.first_seen
    assert_equal '2024-12', ep.last_seen
  end

  def test_bracket_access
    ep = ApacheAge::EdgeProperties.new(confidence: 0.5)
    assert_equal 0.5, ep[:confidence]
    assert_nil ep[:unknown]
  end
end

class ApacheAgeTraverseResultTest < Minitest::Test
  def test_basic
    tr = ApacheAge::TraverseResult.new(entity_id: 'abc', object_type: 'vertex')
    assert_equal 'abc', tr.entity_id
    assert_equal 'vertex', tr.object_type
  end

  def test_bracket_access
    tr = ApacheAge::TraverseResult.new(entity_id: 'v1', object_type: 'vertex')
    assert_equal 'v1', tr[:entity_id]
    assert_equal 'vertex', tr[:object_type]
    assert_nil tr[:nonexistent]
  end
end

class ApacheAgeEdgeTraverseResultTest < Minitest::Test
  def test_basic
    props = ApacheAge::EdgeProperties.new(confidence: 0.9)
    etr = ApacheAge::EdgeTraverseResult.new(entity_id: 'e1', object_type: 'edge', properties: props)
    assert_equal 'e1', etr.entity_id
    assert_equal 0.9, etr.properties.confidence
  end

  def test_bracket_access
    props = ApacheAge::EdgeProperties.new(confidence: 0.9)
    etr = ApacheAge::EdgeTraverseResult.new(entity_id: 'e1', object_type: 'edge', properties: props)
    assert_equal 'e1', etr[:entity_id]
    assert_equal 'edge', etr[:object_type]
    assert_nil etr[:nonexistent]
  end
end

class ApacheAgeForwardTraverseResultTest < Minitest::Test
  def test_basic
    ftr = ApacheAge::ForwardTraverseResult.new(source_object_id: 'a', target_object_id: 'b', target_object_type: 'vertex')
    assert_equal 'a', ftr.source_object_id
    assert_equal 'b', ftr.target_object_id
    assert_equal 'vertex', ftr.target_object_type
  end

  def test_bracket_access
    ftr = ApacheAge::ForwardTraverseResult.new(source_object_id: 'a', target_object_id: 'b', target_object_type: 'vertex')
    assert_equal 'a', ftr[:source_object_id]
    assert_nil ftr[:nonexistent]
  end
end

class ApacheAgeReverseTraverseResultTest < Minitest::Test
  def test_basic
    rtr = ApacheAge::ReverseTraverseResult.new(source_object_id: 'a', target_object_id: 'b', source_object_type: 'vertex')
    assert_equal 'a', rtr.source_object_id
    assert_equal 'b', rtr.target_object_id
    assert_equal 'vertex', rtr.source_object_type
  end

  def test_bracket_access
    rtr = ApacheAge::ReverseTraverseResult.new(source_object_id: 'a', target_object_id: 'b', source_object_type: 'vertex')
    assert_equal 'a', rtr[:source_object_id]
    assert_nil rtr[:nonexistent]
  end
end
