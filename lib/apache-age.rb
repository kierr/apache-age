# frozen_string_literal: true

require 'sorbet-runtime'
require 'apache_age/version'
require 'apache_age/agtype_parser'
require 'apache_age/vertex'
require 'apache_age/edge'
require 'apache_age/path'
require 'apache_age/connection'
require 'apache_age'

# Auto-load Railtie when Rails is present
require 'apache_age/railtie' if defined?(Rails::Railtie)
