require_relative 'whisper_cpp'

class Subtitler
  module WhisperX
    include WhisperCpp

    mattr_accessor :api
    self.api = URI.parse ENV['WHISPERX_SERVER'] if ENV['WHISPERX_SERVER']

    # Transcribe an audio file using WhisperX.
    # Params:
    #   path        – path to audio file
    #   format:     – whisper response_format (default: 'verbose_json').
    #                 JSON formats return Subtitle; non-JSON formats return String.
    #   merge_words – when true (default) contiguous tokens without a leading
    #                 space are merged into a single word and their timings
    #                 are combined (start of first, end of last).
    #   **extra     – passed directly to whisper
    def transcribe path, format: 'verbose_json', merge_words: true, **extra
      transcribe_with_params(path, format: format, merge_words: merge_words, temperature_inc: '0.2', **extra)
    end
  end
end
