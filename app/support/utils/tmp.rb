require 'tmpdir'

module Utils
  module Tmp
    module_function

    # Honours TMPDIR/TMP/TEMP through Dir.tmpdir.
    def root = Dir.tmpdir

    def dir(prefix, parent = nil, &block) = Dir.mktmpdir(prefix, parent || root, &block)
  end
end
