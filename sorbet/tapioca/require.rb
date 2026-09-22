# typed: true
# frozen_string_literal: true

# These gems are optional runtime dependencies loaded via `defined?` guards.
# Sorbet needs them required statically for constant resolution.
require 'pg'
require 'active_record'
require 'active_support'
require 'rails'
