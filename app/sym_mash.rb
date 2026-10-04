require 'hashie'

class SymMash < ::Hashie::Mash

  disable_warnings

  include Hashie::Extensions::Mash::SymbolizeKeys

  # Wrapping one that is already a SymMash would copy it, and several callers compare identity.
  def self.wrap(value) = value.is_a?(self) ? value : new(value)

end
