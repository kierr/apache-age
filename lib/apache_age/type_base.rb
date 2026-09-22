# typed: strict
# frozen_string_literal: true

module ApacheAge
  # Shared behavior for Vertex and Edge types: field access via [], to_h,
  # and derived apply_annotation logic.
  module TypeBase
    extend T::Sig

    sig { returns(T::Array[Symbol]) }
    def fields
      T.cast(T.unsafe(self).class.const_get(:FIELDS), T::Array[Symbol])
    end

    # Access a field by name (String or Symbol).
    sig { params(key: T.any(String, Symbol)).returns(T.untyped) }
    def [](key)
      sym_key = key.to_sym
      T.unsafe(self).send(sym_key) if fields.include?(sym_key)
    end

    # Return a Hash representation of all declared fields.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      fields.to_h { |f| [f, T.unsafe(self).send(f)] }
    end
  end
end
