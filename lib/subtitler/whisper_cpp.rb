require 'tempfile'

require_relative '../zipper'
require_relative 'segments'
require_relative 'timestamps'
require_relative 'translator'

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

    # Convert verbose_json into SRT with inline per-word timings.
    # When normalize: true (default), adjacent short segments are merged to produce
    # typical movie-style subtitles (max ~2 lines / similar length).
    # Backward-compat: legacy stdsub overrides normalize when provided.
    def srt_convert subtitle, normalize: true, word_tags: true, stdsub: nil
      raise TypeError, 'subtitle must be a Subtitler::Subtitle' unless subtitle.is_a?(Subtitle)

      use_norm = stdsub.nil? ? normalize : stdsub
      subtitle.merge_adjacent! if use_norm
      subtitle.to_srt(word_tags: word_tags)
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

    # Delegate to centralized VTT converter
    def vtt_convert subtitle, normalize: true, word_tags: true, stdsub: nil
      raise TypeError, 'subtitle must be a Subtitler::Subtitle' unless subtitle.is_a?(Subtitle)

      use_norm = stdsub.nil? ? normalize : stdsub
      if use_norm
        subtitle.split_long_entries!(max_chars: Subtitler::Translator::MAX_SUBTITLE_CHARS)
        subtitle.merge_adjacent!(max_chars: Subtitler::Translator::MAX_SUBTITLE_CHARS)
      end
      subtitle.to_vtt(word_tags: word_tags)
    end

    # Translate using sentence-aware regrouping handled by Subtitler::Translator
    def translate subtitle, from:, to:
      Subtitler::Translator.translate subtitle, from: from, to: to
    end

    private

    def merge_split_words!(subtitle)
      raise TypeError, 'subtitle must be a Subtitler::Subtitle' unless subtitle.is_a?(Subtitle)

      subtitle.merge_split_words!
    end
  end
end
