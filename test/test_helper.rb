# typed: strict
# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  enable_coverage :branch
  add_filter '/test/'
  add_filter '/vendor/'
  # RATIONALE: Lower thresholds in CI where PostgreSQL+AGE is unavailable
  # and integration tests are skipped (30 skipped tests = ~15% of lines uncovered).
  # Full coverage is enforced locally where the database is available.
  # Would need CI to run a PostgreSQL+AGE service container to reconsider.
  if ENV['CI']
    minimum_coverage line: 70, branch: 55
  else
    minimum_coverage line: 90, branch: 70
  end
end

require 'minitest/autorun'
require 'apache-age'
