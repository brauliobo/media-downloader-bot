require 'fileutils'
require_relative 'utils/tmp'

require_relative 'voice_separator/demucs'
require_relative 'voice_separator/bs_roformer'
require_relative 'voice_separator/spleeter'
require_relative 'voice_separator/mdx_net'
require_relative 'voice_separator/deep_filter_net'

class VoiceSeparator
  Stems = Data.define(:vocals, :non_vocals)
  BACKEND = const_get(ENV.fetch('VOICE_SEPARATOR', 'Demucs'))

  def self.separate(path, dir:)
    BACKEND.separate(path, dir: dir)
  end

  def self.with_stems(path, dir: nil)
    Utils::Tmp.dir('voice-separation-', dir) { |workdir| yield separate(path, dir: workdir) }
  end
end
