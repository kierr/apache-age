# typed: ignore
# frozen_string_literal: true

require 'rake/testtask'
require 'rubocop/rake_task'
require 'sorbet-runtime'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.libs << 'test'
  t.test_files = FileList['test/**/*_test.rb']
end

RuboCop::RakeTask.new

namespace :sorbet do
  desc 'Run Sorbet type checker'
  task(:tc) { sh 'srb tc' }

  desc 'Generate RBI files via Tapioca'
  task(:rbi) { sh 'tap init && tap dsl && tap gem' }
end

desc 'Run all checks (test, lint, typecheck)'
task ci: [:test, :rubocop, 'sorbet:tc']

task default: :test
