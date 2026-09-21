# typed: strong
# frozen_string_literal: true

module ApacheAge
  # Minimal Railtie — auto-configures logger and graph_name from Rails
  # config when the gem is used in a Rails application.
  #
  # No ActiveRecord callbacks or session management (those are application
  # concerns, not the driver's).
  class Railtie < Rails::Railtie
    config.apache_age = ActiveSupport::OrderedOptions.new

    initializer 'apache_age.configure' do |_app|
      ApacheAge.graph_name = config.apache_age.graph_name if config.apache_age.graph_name

      # Use SemanticLogger when available (Rails apps commonly have it),
      # otherwise use the default stdlib Logger.
      if defined?(SemanticLogger)
        ApacheAge.logger = SemanticLogger['ApacheAge']
      elsif Rails.respond_to?(:logger) && Rails.logger
        ApacheAge.logger = Rails.logger
      end
    end
  end
end
