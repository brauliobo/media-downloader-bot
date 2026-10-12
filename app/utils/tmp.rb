require 'tmpdir'
require 'securerandom'
require 'fileutils'

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
      previous = ENV['TMPDIR']
      ENV['TMPDIR'] = dir
      yield dir
    ensure
      ENV['TMPDIR'] = previous
    end
  end
end
