require 'tempfile'

require_relative '../zipper'
require_relative 'subtitle'
require_relative 'timestamps'

class Subtitler
  module WhisperCpp

    mattr_accessor :api
    self.api = URI.parse ENV['WHISPER_CPP_SERVER'] if ENV['WHISPER_CPP_SERVER']

    # Transcribe an audio file using whisper.cpp.
    # Params:
    #   path        – path to audio file
    #   format:     – whisper.cpp response_format (default: 'verbose_json').
    #                 JSON formats return Subtitle; non-JSON formats return String.
    #   merge_words – when true (default) contiguous tokens without a leading
    #                 space are merged into a single word and their timings
    #                 are combined (start of first, end of last). This fixes
    #                 whisper.cpp artefact where a single Portuguese word is
    #                 emitted as two tokens (e.g. " test" + "ando").
    #   **extra     – passed directly to whisper.cpp
    def transcribe path, format: 'verbose_json', merge_words: true, **extra
      transcribe_with_params(path, format: format, merge_words: merge_words, language: 'auto', **extra)
    end

    protected

    def transcribe_with_params path, format:, merge_words:, language: nil, **extra
      out = Zipper.with_audio_wav(path) do |file|
        params = {
          file:             file,
          temperature:      '0.0',
          response_format:  format,
          **extra
        }
        params[:language] = language if language

        url = "#{api.scheme}://#{api.host}:#{api.port}/inference"
        res = Utils::HTTP.post(url, params)
        raise "TTS failed: #{res.code}" unless res.code == '200'

        res.body
      end

      return out unless format.to_s.include?('json')

      subtitle = Subtitle.from_whisper_verbose_json(out)
      subtitle.replace_language!(Subtitler.normalize_lang(subtitle.language))
      merge_split_words!(subtitle) if merge_words
      subtitle
    end

    private

    def merge_split_words!(subtitle)
      raise TypeError, 'subtitle must be a Subtitler::Subtitle' unless subtitle.is_a?(Subtitle)

      subtitle.merge_split_words!
    end
  end
end
