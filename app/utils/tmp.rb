require 'tmpdir'
require 'securerandom'
require 'fileutils'
require 'digest'

module Utils
  # The one place scratch files come from. Inside +within+ the root is the job's input dir, so
  # Ruby and every child process (tesseract, ffmpeg, gs...) keep their temporaries there, not in /tmp.
  module Tmp
    module_function

    # Honours TMPDIR/TMP/TEMP through Dir.tmpdir.
    def root = Dir.tmpdir

    def dir(prefix, parent = nil, &block) = Dir.mktmpdir(prefix, parent || root, &block)

    # A unique path that does not exist yet, for tools that create their own output.
    def path(prefix, ext = '') = File.join(root, "#{prefix}#{SecureRandom.hex(6)}#{ext}")

    # Yields a unique path and removes whatever was written there.
    def file(prefix, ext = '')
      target = path(prefix, ext)
      yield target
    ensure
      FileUtils.rm_rf(target)
    end

    # Points TMPDIR at +dir+ for the block; ENV is process-wide so worker threads and children follow.
    def within(dir)
      previous, previous_scope = ENV['TMPDIR'], @scope
      ENV['TMPDIR'] = @scope = dir
      yield dir
    ensure
      ENV['TMPDIR'], @scope = previous, previous_scope
    end

    # Like +dir+, but inside +within+ (a job) the directory is named by +key+, what the work is about, and an interrupted block
    # leaves it: the same work run again, in the same job, resumes in it. It is removed once the block ends well.
    def resumable(prefix, key, &block)
      return dir(prefix, &block) unless @scope

      FileUtils.mkdir_p(path = File.join(@scope, "#{prefix}#{digest(key)}"))
      yield(path).tap { FileUtils.rm_rf(path) }
    end

    # The text +file+ yields under +key+ (what else the text depends on), computed once per job even if the job restarts.
    def cached(name, file, **key)
      return yield unless @scope

      path = File.join(@scope, name, digest([Digest::SHA256.file(file).hexdigest, key]))
      return File.read(path) if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      yield.tap { |text| File.write(path, text) }
    end

    def digest(key) = Digest::SHA256.hexdigest(key.to_json)[0, 24]
  end
end
