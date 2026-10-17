require 'securerandom'
require 'fileutils'

module Utils
  # A file that exists only whole: written aside, under a name Tmp.resumable clears when it resumes, and moved into place. A run
  # killed halfway leaves no file a resumed one would take for done.
  module Atomic
    PREFIX = '.part-'

    module_function

    # Yields the path to write; the file is at `path` once the block ends well.
    def write(path)
      part = File.join(File.dirname(path), "#{PREFIX}#{SecureRandom.hex(4)}-#{File.basename(path)}")
      yield part
      File.rename(part, path)
      path
    ensure
      FileUtils.rm_f(part) if part
    end

    def binwrite(path, data) = write(path) { |part| File.binwrite(part, data) }

    def copy(source, path) = write(path) { |part| FileUtils.cp(source, part) }
  end
end
