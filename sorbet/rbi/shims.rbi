# typed: true

# Shim declarations for nested Rails constants that Sorbet can't resolve
# from the gem RBIs alone. These are all provided by the respective gems
# at runtime.

module Rails
  class Railtie
    extend T::Sig

    sig { params(name: String, blk: T.proc.void).void }
    def self.initializer(name, &blk); end
  end
end

module ActiveRecord
  module ConnectionAdapters
    class AbstractAdapter
      extend T::Sig

      sig { params(kind: Symbol, timing: Symbol, blk: T.proc.params(conn: AbstractAdapter).void).void }
      def self.set_callback(kind, timing, &blk); end

      sig { returns(T.untyped) }
      def raw_connection; end
    end
    module SchemaStatements; end
    module DatabaseStatements; end
  end

  class Error < StandardError; end
  class StatementInvalid < Error; end
  class Railtie < Rails::Railtie; end

  class Base
    extend T::Sig

    sig { returns(T.untyped) }
    def self.connection; end
  end
end

module ActiveModel
  class Error; end
end

module ActiveSupport
  module Multibyte
    class Chars; end
  end

  class SafeBuffer < String; end
  class StringInquirer < String; end
  class ArrayInquirer < Array; end
  class TimeZone; end

  module DateAndTime
    module Zones; end
    module Calculations; end
  end

  module ErrorCollector; end

  module Testing
    module ErrorReporterAssertions
      module ErrorCollector
        class Report; end
      end
    end
  end

  sig { params(name: Symbol, blk: T.proc.void).void }
  def self.on_load(name, &blk); end
end

class String
  sig { returns(String) }
  def squish; end
end

class HashWithIndifferentAccess < Hash; end
