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
  task(:rbi) { sh 'bundle exec tapioca init && bundle exec tapioca dsl && bundle exec tapioca gem' }

  desc 'Check committed RBIs are up to date (fail if tapioca gem produces diffs)'
  task :rbi_verify do
    baseline = `git status --short sorbet/rbi/`.strip
    sh 'bundle exec tapioca gem'
    after = `git status --short sorbet/rbi/`.strip
    if baseline != after
      puts 'ERROR: Committed RBI files differ from tapioca gem output.'
      puts "Run 'bundle exec rake sorbet:rbi' locally and commit the changes."
      exit 1
    end
    puts 'RBI files are up to date.'
  end

  desc 'Print Spoom typed coverage report'
  task :metrics do
    sh 'bundle exec spoom srb coverage'
  end

  desc 'Bump sigils toward stronger typing where possible'
  task :bump do
    sh 'bundle exec spoom bump'
  end
end

desc 'Run all checks (test, lint, typecheck)'
task ci: [:test, :rubocop, 'sorbet:tc']

task default: :test
