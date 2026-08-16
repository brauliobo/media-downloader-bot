require_relative 'subtitle'

class Subtitler
  class SRT
    def self.filter_noise(srt)
      Subtitle.from_srt(srt).reject_noise!.to_srt
    end
  end
end
