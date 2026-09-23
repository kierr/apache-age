# frozen_string_literal: true

$LOAD_PATH.unshift(File.join(__dir__, 'lib'))
require 'apache_age/version'

Gem::Specification.new do |spec|
  spec.name          = 'apache_age'
  spec.version       = ApacheAge::VERSION
  spec.authors       = ['kierr']
  spec.email         = []

  spec.summary       = 'Apache AGE graph database client for Ruby'
  spec.description   = <<~DESC
    A typed Ruby driver for Apache AGE, the PostgreSQL extension for graph databases.
    Provides agtype parsing, graph lifecycle management, Cypher query execution
    with parameterized statements, batch loading, and Vertex/Edge/Path domain models —
    matching the API surface of the official Python, Node.js, Go, and JDBC drivers.
  DESC
  spec.homepage      = 'https://github.com/kierr/apache-age'
  spec.license       = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.3'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => 'https://github.com/kierr/apache-age',
    'changelog_uri' => 'https://github.com/kierr/apache-age/blob/main/CHANGELOG.md',
    'bug_tracker_uri' => 'https://github.com/kierr/apache-age/issues',
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir.glob('{lib}/**/*') + %w[README.md CHANGELOG.md LICENSE]
  spec.bindir        = 'exe'
  spec.executables   = []
  spec.require_paths = ['lib']

  spec.add_dependency 'bigdecimal', ['>= 3.1', '< 5.0']
  spec.add_dependency 'pg', '~> 1.5'
  spec.add_dependency 'sorbet-runtime', '~> 0.5'

  spec.add_development_dependency 'activerecord'
  spec.add_development_dependency 'minitest'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'semantic_logger'
end
