require 'tmpdir'
require 'fileutils'

# Tiny real media made by ffmpeg once per run and copied, so a spec probes and converts actual files.
module MediaFiles
  SOURCES = {
    mp4: ->(d) { %W[-f lavfi -i testsrc=d=#{d}:s=64x64:r=5 -f lavfi -i sine=d=#{d} -shortest -pix_fmt yuv420p] },
    m4a: ->(d) { %W[-f lavfi -i sine=d=#{d}] },
    mp3: ->(d) { %W[-f lavfi -i sine=d=#{d}] },
    jpg: ->(_) { %w[-f lavfi -i testsrc=s=64x64 -frames:v 1] }
  }.freeze

  def self.template(ext, seconds)
    @templates ||= {}
    @templates[[ext, seconds]] ||= File.join(@dir ||= Dir.mktmpdir('media-files-'), "#{seconds}.#{ext}").tap do |path|
      system('ffmpeg', '-v', 'error', '-y', *SOURCES.fetch(ext).(seconds), path, exception: true)
    end
  end

  def media_file(path, seconds: 1)
    FileUtils.cp(MediaFiles.template(File.extname(path).delete('.').to_sym, seconds), path)
    path
  end
end
