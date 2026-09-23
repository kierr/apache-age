# apache-age

A Ruby driver for [Apache AGE](https://age.apache.org/), the PostgreSQL extension for graph databases. Abstracted from a large rails monolith, used in production (NOT aspirational vibe-slop!)

Provides agtype parsing, graph lifecycle management, Cypher query execution with parameterized statements, and Vertex/Edge/Path domain models.

## Installation

```bash
gem install apache-age
```

Or in your Gemfile:

```ruby
gem 'apache-age'
```

## Quick Start

```ruby
require 'apache-age'

# Connect to PostgreSQL with AGE installed
conn = PG.connect(dbname: 'mydb')

# Prepare the connection for AGE usage
ApacheAge.setup_connection(conn)

# Create a graph
ApacheAge.create_graph!(name: 'my_graph')

# Execute a Cypher query (set graph_name first, or pass it inline in the cypher)
ApacheAge.graph_name = 'my_graph'

results = ApacheAge.query_cypher(
  'CREATE (n:Person {name: $name, age: $age}) RETURN n',
  columns: ['n'],
  params: { name: 'Alice', age: 30 }
)

# Query vertices
results = ApacheAge.query_cypher(
  'MATCH (n:Person) RETURN n',
  columns: ['n']
)

results.each do |row|
  vertex = row['n']  # => ApacheAge::Vertex
  puts "#{vertex.label}: #{vertex.properties}"
end

# Drop a graph
ApacheAge.drop_graph!(name: 'my_graph', cascade: true)
```

## API

### Connection Setup

```ruby
# Prepare a PG connection for AGE (loads extension, sets search_path, creates extension)
ApacheAge.setup_connection(conn)

# Or let the gem auto-detect an ActiveRecord connection
ApacheAge.setup_connection  # uses current connection

# Skip automatic extension creation
ApacheAge.setup_connection(conn, create_extension: false)
```

### Configuration

```ruby
ApacheAge.graph_name = 'my_graph'   # default graph for operations
ApacheAge.logger = Logger.new($stderr)
```

### Graph Lifecycle

```ruby
ApacheAge.create_graph!(name: 'social_network')
ApacheAge.graph_exists?(name: 'social_network')  # => true
ApacheAge.drop_graph!(name: 'social_network', cascade: false)
```

### Query Execution

```ruby
# Set a default graph name for queries
ApacheAge.graph_name = 'my_graph'

# Simple query with array columns (type defaults to agtype)
ApacheAge.query_cypher('MATCH (n) RETURN n', columns: ['n'])

# With full column definition string
ApacheAge.query_cypher('MATCH (a)-[e]->(b) RETURN a, e, b',
  columns: 'a ag_catalog.agtype, e ag_catalog.agtype, b ag_catalog.agtype')

# With parameters (uses age_prepare_cypher for safe parameterized execution)
ApacheAge.query_cypher(
  'MATCH (n:Person {name: $name}) RETURN n',
  columns: ['n'],
  params: { name: 'Alice' }
)
```

### Agtype Parsing

```ruby
# Parse raw agtype strings
ApacheAge.parse_agtype('42')                              # => 42
ApacheAge.parse_agtype('"hello"')                         # => "hello"
ApacheAge.parse_agtype('3.14::numeric')                   # => BigDecimal("3.14")
ApacheAge.parse_agtype('{"id":1,"label":"Person",...}::vertex')  # => Vertex
ApacheAge.parse_agtype('{"id":2,"label":"KNOWS",...}::edge')     # => Edge
ApacheAge.parse_agtype('[...]::path')                      # => Path
```

### Domain Models

```ruby
vertex = ApacheAge::Vertex.new(id: 1, label: 'Person', properties: { 'name' => 'Alice' })
vertex.id         # => 1
vertex.label      # => "Person"
vertex['name']    # => "Alice"  (delegates to properties)
vertex.to_h       # => { "id" => 1, "label" => "Person", "properties" => {...} }

edge = ApacheAge::Edge.new(id: 2, label: 'KNOWS', start_id: 1, end_id: 3, properties: {})
edge.start_id     # => 1
edge.end_id       # => 3

path = ApacheAge::Path.new(entities: [v1, e1, v2])
path.vertices     # => [v1, v2]
path.edges        # => [e1]
path.length       # => 1
```

### Utilities

```ruby
# Escape values for Cypher string interpolation
ApacheAge.cypher_escape("it's")  # => "it''s"

# Encode Ruby values as agtype literals
ApacheAge.agtype_encode(42)              # => "42"
ApacheAge.agtype_encode('hello')         # => '"hello"'
ApacheAge.agtype_encode(BigDecimal('3.14'))  # => "3.14::numeric"
ApacheAge.agtype_encode({ 'key' => 'val' })  # => '{"key": "val"}'
```

## Rails Integration

The gem includes a Railtie that auto-configures the logger. Set the graph
name in an initializer:

```ruby
# config/initializers/apache_age.rb
ApacheAge.graph_name = 'my_graph'
```

When SemanticLogger is present, the gem uses it automatically. Otherwise it falls back to the Rails logger or stdlib Logger. The gem auto-detects ActiveRecord and reuses your connection pool — no manual `setup_connection` call is needed in a Rails app.

## Two surfaces: driver core (autoloaded) and entity layer (opt-in)

The autoloaded core (`require 'apache-age'`) is a driver matching the official
Apache AGE driver API: graph lifecycle, `query_cypher`, agtype parsing, and
AGE's own `Vertex`/`Edge`/`Path` domain models. This is what a general AGE
user needs.

The entity layer is opt-in for apps that model vertices as `{object_id,
object_type}` and edges with `confidence`/`first_seen`/`last_seen` properties
(e.g. entity-resolution / knowledge-graph apps). It adds `create_vertex`,
`create_edge` (with `directionality:`), `traverse`/`traverse_batch`, typed
`TraverseResult`/`EdgeTraverseResult`/`EdgeProperties`, and the other entity
CRUD methods. Load it alongside the driver:

```ruby
require 'apache-age'
require 'apache-age/entity'   # opt-in entity layer
```

This mirrors the existing `require 'apache-age/bulk_load'` opt-in pattern.

## Requirements

- Ruby >= 3.3
- PostgreSQL with Apache AGE extension installed (tested on 1.7.0 and 1.8.0)
- `pg` gem

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/kierr/apache-age).
See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and development instructions.

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md) code of conduct.

## License

Apache License 2.0, matching the Apache AGE project.
