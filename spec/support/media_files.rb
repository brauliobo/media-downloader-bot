require 'tmpdir'
require 'fileutils'

# Tiny real media made by ffmpeg once per run and copied, so a spec probes and converts actual files.
module MediaFiles
  SOURCES = {
    mp4: %w[-f lavfi -i testsrc=d=1:s=64x64:r=5 -f lavfi -i sine=d=1 -shortest -pix_fmt yuv420p],
    m4a: %w[-f lavfi -i sine=d=1],
    mp3: %w[-f lavfi -i sine=d=1],
    jpg: %w[-f lavfi -i testsrc=s=64x64 -frames:v 1]
  }.freeze

  def self.template(ext)
    @templates ||= {}
    @templates[ext] ||= File.join(@dir ||= Dir.mktmpdir('media-files-'), "template.#{ext}").tap do |path|
      system('ffmpeg', '-v', 'error', '-y', *SOURCES.fetch(ext), path, exception: true)
    end
  end

  def media_file(path)
    FileUtils.cp(MediaFiles.template(File.extname(path).delete('.').to_sym), path)
    path
  end
end
