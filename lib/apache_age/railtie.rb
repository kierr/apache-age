# typed: true
# frozen_string_literal: true

# Railtie auto-loads when ActiveRecord::Base is defined.
# Non-Rails consumers never see this file.

return unless defined?(ActiveRecord::Base)

require 'rails/railtie'

module ApacheAge
  class Railtie < Rails::Railtie
    initializer 'apache_age.logger' do
      ApacheAge.logger = SemanticLogger['ApacheAge'] if defined?(SemanticLogger)
    end

    initializer 'apache_age.connection_hooks' do
      # Register AR connection pool callbacks for AGE session management.
      # When AR recycles a connection, evict it from the AGE-loaded set
      # so the next use re-initializes the AGE session.
      ActiveSupport.on_load(:active_record) do
        ActiveRecord::ConnectionAdapters::AbstractAdapter.set_callback(:checkout, :after) do |conn|
          # no-op on checkout — AGE loads lazily
        end

        ActiveRecord::ConnectionAdapters::AbstractAdapter.set_callback(:checkin, :after) do |conn|
          if conn.respond_to?(:raw_connection) && conn.raw_connection.respond_to?(:backend_pid)
            ApacheAge.evict_age_loaded_connection(conn.raw_connection.backend_pid)
          end
        end
      end
    end
  end
end
