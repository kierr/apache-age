# typed: strong
# frozen_string_literal: true

require 'pg'

module ApacheAge
  # Connection dispatch module — selects implementation based on the configured
  # connection type. Auto-detects ActiveRecord when present; falls back to an
  # explicit PG::Connection for standalone usage.
  module Connection
    class << self
      extend T::Sig

      sig { returns(T::Boolean) }
      def active_record?
        defined?(ActiveRecord::Base) && !@pg_connection
      end

      # Execute SQL and return a result.
      # With AR: returns PG::Result (Rails 8.1) or ActiveRecord::Result.
      # With pg: returns PG::Result.
      sig { params(sql: String).returns(T.untyped) }
      def execute(sql)
        if active_record?
          ActiveRecord::Base.connection.execute(sql)
        else
          pg_connection.exec(sql)
        end
      end

      # Returns the current connection object (AR adapter or PG::Connection).
      sig { returns(T.untyped) }
      def current
        if active_record?
          ActiveRecord::Base.connection
        else
          pg_connection
        end
      end

      # Run a block inside a savepoint; no-op if no transaction is active.
      sig { params(name: String, block: T.proc.returns(T.untyped)).returns(T.untyped) }
      def with_savepoint(name, &block)
        if active_record?
          ar_with_savepoint(name, &block)
        else
          pg_with_savepoint(name, &block)
        end
      end

      sig { returns(T::Boolean) }
      def transaction_open?
        if active_record?
          ActiveRecord::Base.connection.transaction_open?
        else
          pg_connection.transaction_status != PG::Connection::PQTRANS_IDLE
        end
      end

      sig { returns(Integer) }
      def backend_pid
        if active_record?
          ActiveRecord::Base.connection.raw_connection.backend_pid
        else
          pg_connection.backend_pid
        end
      end

      sig { void }
      def restore_search_path
        execute('SET search_path = "$user", public')
      end

      sig { params(conn: PG::Connection).void }
      def set_pg_connection(conn)
        @pg_connection = conn
      end

      sig { returns(PG::Connection) }
      def pg_connection
        @pg_connection || Kernel.raise(ArgumentError, "Set ApacheAge.connection = PG::Connection.new(...) or add activerecord to your Gemfile")
      end

      private

      sig { params(name: String, block: T.proc.returns(T.untyped)).returns(T.untyped) }
      def ar_with_savepoint(name, &block)
        conn = ActiveRecord::Base.connection
        conn.create_savepoint(name) if conn.transaction_open?
        yield
      ensure
        if conn.transaction_open?
          begin
            conn.release_savepoint(name)
          rescue ActiveRecord::StatementInvalid
            begin
              conn.rollback_to_savepoint(name)
            rescue StandardError
              nil
            end
          end
        end
      end

      sig { params(name: String, block: T.proc.returns(T.untyped)).returns(T.untyped) }
      def pg_with_savepoint(name, &block)
        return yield unless transaction_open?

        pg_connection.exec("SAVEPOINT #{name}")
        yield
      rescue StandardError
        pg_connection.exec("ROLLBACK TO SAVEPOINT #{name}") rescue nil
        raise
      ensure
        pg_connection.exec("RELEASE SAVEPOINT #{name}") rescue nil if transaction_open?
      end
    end
  end
end
