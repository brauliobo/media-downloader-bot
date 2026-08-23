require 'fileutils'
require 'tmpdir'

require_relative 'voice_separator/demucs'
require_relative 'voice_separator/bs_roformer'

class VoiceSeparator
  Stems = Data.define(:vocals, :non_vocals)
  BACKEND = const_get(ENV.fetch('VOICE_SEPARATOR', 'Demucs'))

  def self.separate(path, dir:)
    BACKEND.separate(path, dir: dir)
  end

  def self.with_stems(path, dir: nil)
    workdir = Dir.mktmpdir('voice-separation-', dir)
    yield separate(path, dir: workdir)
  ensure
    FileUtils.remove_entry(workdir) if workdir && Dir.exist?(workdir)
  end
end
