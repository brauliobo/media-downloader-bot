require 'shellwords'

module Audiobook
  # Base speech unit for audio synthesis, path generation, YAML serialization.
  class Speech
    # Default pause (seconds) between units – subclasses override.
    PAUSE = 0.0

    attr_accessor :pause, :start, :end

    def initialize
      @pause = self.class::PAUSE
    end

    # Hash representation suitable for YAML.
    def to_h
      h = {}
      h['start'] = start if start
      h['end']   = self.end if self.end
      h.merge!(extra_hash)
    end

    # Generate WAV file for this speech unit
    # dir: directory to write into
    # idx: index label for file naming (string or integer)
    # lang: tts language
    def to_wav(dir, idx, lang: 'en')
      wav_path = File.join(dir, "#{idx}.wav")
      return wav_path if File.exist?(wav_path)

      synthesize_audio(wav_path, lang)
      wav_path
    end

    def pause_file(dir)
      Zipper.get_pause_file(pause, dir) if pause > 0
    end

    protected

    def synthesize_audio(_wav_path, _lang)
      # Default: generate silence (0.5 s)
      cmd = "#{Zipper::FFMPEG} -f lavfi -i anullsrc=channel_layout=mono:sample_rate=22050 -t 0.5 #{Shellwords.escape(_wav_path)}"
      system(cmd)
    end

    def extra_hash
      {}
    end
  end
end
