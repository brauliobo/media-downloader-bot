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

    # The audio of this speech unit: the stored one if it was already made, else synthesized (a sentence is stored as Opus).
    # dir: directory to write into
    # idx: index label for file naming (string or integer)
    # lang: tts language
    # stl: status line object (optional, for compatibility)
    def to_wav(dir, idx, lang: 'en', stl: nil, tts_options: {})
      wav_path = File.join(dir, "#{idx}.wav")
      AudioFiles.stored?(wav_path) ? AudioFiles.stored_path(wav_path) : synthesize_audio(wav_path, lang, tts_options: tts_options)
    end

    def pause_file(dir)
      AudioFiles.pause(pause, dir) if pause > 0
    end

    protected

    # Writes the audio and returns its path.
    def synthesize_audio(wav_path, _lang, tts_options: {})
      AudioFiles.silence(wav_path, 0.5)
      wav_path
    end

    def extra_hash
      {}
    end
  end
end
