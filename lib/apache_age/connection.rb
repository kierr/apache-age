# typed: strong
# frozen_string_literal: true

require 'pg'

module ApacheAge
  # Connection dispatch module — selects implementation based on the configured
  # connection type. Auto-detects ActiveRecord when present; falls back to an
  # explicit PG::Connection for standalone usage.
  module Connection
    VALID_SAVEPOINT_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    # Connection mode determines how SQL is dispatched.
    # :auto — detect ActiveRecord, fall back to PG (default, backward-compatible)
    # :active_record — always use ActiveRecord::Base.connection
    # :pg — always use the explicit PG::Connection (set via pg_connection=)
    @connection_mode = T.let(:auto, Symbol)

    class << self
      extend T::Sig

      sig { returns(Symbol) }
      attr_reader :connection_mode

      # Set the connection mode. Logs a diagnostic when switching from :auto
      # to an explicit mode.
      sig { params(mode: Symbol).void }
      def connection_mode=(mode)
        valid = %i[auto active_record pg]
        unless valid.include?(mode)
          Kernel.raise ArgumentError, "Invalid connection_mode #{mode.inspect} — must be one of #{valid.inspect}"
        end
        if @connection_mode == :auto && mode != :auto
          ApacheAge.log(:info, 'age_graph.connection_mode_set',
                        message: "Switching from :auto to :#{mode}",
                        new_mode: mode)
        end
        @connection_mode = mode
      end

      sig { returns(T::Boolean) }
      def active_record?
        case @connection_mode
        when :active_record then true
        when :pg then false
        else # :auto
          defined?(ActiveRecord::Base) && !@pg_connection
        end
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
      sig { params(name: String, blk: T.proc.returns(T.untyped)).returns(T.untyped) }
      def with_savepoint(name, &blk)
        validate_savepoint_name!(name)
        if active_record?
          ar_with_savepoint(name, &blk)
        else
          pg_with_savepoint(name, &blk)
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

      # Close the standalone PG::Connection and release the reference.
      # No-op when using ActiveRecord (the pool owns the lifecycle).
      # After calling disconnect, pg_connection= must be called again
      # before the next query.
      sig { void }
      def disconnect
        return unless @pg_connection

        @pg_mutex ||= T.let(Mutex.new, T.nilable(Mutex))
        @pg_mutex.synchronize do
          next unless @pg_connection

          begin
            @pg_connection.close
          rescue StandardError
            nil
          end
          @pg_connection = nil
        end
      end

      # Set the standalone PG::Connection. Use this for non-AR setups.
      sig { params(conn: PG::Connection).void }
      def pg_connection=(conn)
        @pg_mutex ||= T.let(Mutex.new, T.nilable(Mutex))
        @pg_mutex.synchronize { @pg_connection = conn }
      end

      sig { returns(PG::Connection) }
      def pg_connection
        @pg_mutex ||= T.let(Mutex.new, T.nilable(Mutex))
        @pg_mutex.synchronize do
          @pg_connection || Kernel.raise(
            ArgumentError,
            'Set ApacheAge.pg_connection = PG::Connection.new(...) ' \
            'or add activerecord to your Gemfile'
          )
        end
      end

      # Backward-compatible alias for pg_connection=.
      sig { params(conn: PG::Connection).void }
      def set_pg_connection(conn)
        self.pg_connection = conn
      end

      private

      sig { params(name: String).void }
      def validate_savepoint_name!(name)
        return if name.match?(VALID_SAVEPOINT_NAME)

        Kernel.raise ArgumentError,
                     "Invalid savepoint name '#{name}' — must match #{VALID_SAVEPOINT_NAME.source}"
      end

      sig { params(name: String, blk: T.proc.returns(T.untyped)).returns(T.untyped) }
      def ar_with_savepoint(name, &blk)
        conn = ActiveRecord::Base.connection
        conn.create_savepoint(name) if conn.transaction_open?
        blk.call
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

      sig { params(name: String, blk: T.proc.returns(T.untyped)).returns(T.untyped) }
      def pg_with_savepoint(name, &blk)
        return blk.call unless transaction_open?

        pg_connection.exec("SAVEPOINT #{name}")
        blk.call
      rescue StandardError
        begin
          pg_connection.exec("ROLLBACK TO SAVEPOINT #{name}")
        rescue StandardError
          nil
        end
        raise
      ensure
        if transaction_open?
          begin
            pg_connection.exec("RELEASE SAVEPOINT #{name}")
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end

# Auto-disconnect at exit to close the standalone PG connection cleanly.
at_exit { ApacheAge::Connection.disconnect }
