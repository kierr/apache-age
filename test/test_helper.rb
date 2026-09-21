# typed: strict
# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  enable_coverage :branch
  add_filter '/test/'
  add_filter '/vendor/'
  minimum_coverage 90
  minimum_coverage_by_file 80
end

require 'minitest/autorun'
require 'apache-age'
