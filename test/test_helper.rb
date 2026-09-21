# typed: strict
# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  enable_coverage :branch
  add_filter '/test/'
  add_filter '/vendor/'
  minimum_coverage 60
  minimum_coverage_by_file 30
end

require 'minitest/autorun'
require 'apache-age'
