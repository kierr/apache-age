# typed: true
# frozen_string_literal: true

# These gems are optional runtime dependencies loaded via `defined?` guards.
# Sorbet needs them required statically for constant resolution.
# Guard with `rescue LoadError` so CI (which may not have all gems) still works.
begin
  require 'pg'
rescue LoadError # optional: not installed in CI
end
begin
  require 'active_record'
rescue LoadError # optional: not installed in CI
end
begin
  require 'active_support'
rescue LoadError # optional: not installed in CI
end
