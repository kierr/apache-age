## 0.1.0 (2025-09-20)

Initial release.

- Full recursive-descent agtype parser matching Agtype.g4 grammar
- Vertex, Edge, Path domain models (matching Python/Node.js/Go drivers)
- Graph lifecycle: `create_graph`, `drop_graph`, `graph_exists?`
- Cypher query execution: `query_cypher` with parameterized statements via `age_prepare_cypher`
- PG connection setup: `setup_connection` (equivalent to Python `setUpAge` / Node.js `setAGETypes`)
- Rails integration via Railtie (logger + graph_name auto-configuration)
- Agtype encoding: `agtype_encode` for building Cypher parameter literals
- Cypher string escaping: `cypher_escape` public utility
- Input validation: graph names, label names, column names/types
- Deterministic dollar-quoting (matching Node.js driver)
- Surrogate pair support in agtype string parsing
- Keyword boundary checks (prevents `NaNometer` parsing as `NaN`)
