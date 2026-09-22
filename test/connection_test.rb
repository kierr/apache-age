# typed: strict
# frozen_string_literal: true

require_relative 'test_helper'

class ApacheAgeConnectionTest < Minitest::Test
  def setup
    @original_mode = ApacheAge::Connection.connection_mode
  end

  def teardown
    ApacheAge::Connection.connection_mode = @original_mode
    # Reset @pg_connection directly to nil (bypass typed getter)
    mutex = ApacheAge::Connection.instance_variable_get(:@pg_mutex)
    mutex.synchronize do
      ApacheAge::Connection.instance_variable_set(:@pg_connection, nil)
    end
  end

  def test_connection_mode_setter_invalid
    assert_raises(ArgumentError) { ApacheAge::Connection.connection_mode = :invalid }
  end

  def test_connection_mode_setter_valid_transitions
    # Should log and set
    ApacheAge::Connection.connection_mode = :pg
    assert_equal :pg, ApacheAge::Connection.connection_mode

    ApacheAge::Connection.connection_mode = :active_record
    assert_equal :active_record, ApacheAge::Connection.connection_mode
  end

  def test_active_record_when_mode_explicitly_set
    ApacheAge::Connection.connection_mode = :active_record
    assert_predicate ApacheAge::Connection, :active_record?
  end

  def test_not_active_record_when_mode_explicitly_set
    ApacheAge::Connection.connection_mode = :pg
    refute_predicate ApacheAge::Connection, :active_record?
  end

  def test_disconnect_idempotent
    conn = Object.new # Arbitrary object, disconnect calls close and sets nil
    mutex = ApacheAge::Connection.instance_variable_get(:@pg_mutex)
    mutex.synchronize do
      ApacheAge::Connection.instance_variable_set(:@pg_connection, conn)
    end

    ApacheAge::Connection.disconnect
    assert_nil ApacheAge::Connection.instance_variable_get(:@pg_connection)

    # Second disconnect should not raise
    ApacheAge::Connection.disconnect
  end

  def test_validate_savepoint_name_injection
    assert_raises(ArgumentError) do
      ApacheAge::Connection.send(:validate_savepoint_name!, "'; DROP TABLE users; --")
    end
  end

  def test_validate_savepoint_name_invalid_chars
    assert_raises(ArgumentError) { ApacheAge::Connection.send(:validate_savepoint_name!, '1invalid') }
  end

  def test_validate_savepoint_name_valid_long
    # Savepoint name has no length limit unlike graph names
    assert_silent { ApacheAge::Connection.send(:validate_savepoint_name!, 'a' * 100) }
  end

  def test_validate_savepoint_name_valid
    assert_silent { ApacheAge::Connection.send(:validate_savepoint_name!, 'my_savepoint') }
    assert_silent { ApacheAge::Connection.send(:validate_savepoint_name!, 'save1') }
  end
end
