require 'tempfile'
require 'iso-639'

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
    #   format:     – whisper.cpp response_format (default: 'verbose_json')
    #   merge_words – when true (default) contiguous tokens without a leading
    #                 space are merged into a single word and their timings
    #                 are combined (start of first, end of last). This fixes
    #                 whisper.cpp artefact where a single Portuguese word is
    #                 emitted as two tokens (e.g. " test" + "ando").
    #   **extra     – passed directly to whisper.cpp
    def transcribe path, format: 'verbose_json', merge_words: true, **extra
      transcribe_with_params(path, format: format, merge_words: merge_words, language: 'auto', detect_lang: :full, **extra)
    end

    # Convert verbose_json into SRT with inline per-word timings.
    # When normalize: true (default), adjacent short segments are merged to produce
    # typical movie-style subtitles (max ~2 lines / similar length).
    # Backward-compat: legacy stdsub overrides normalize when provided.
    def srt_convert verbose_json, normalize: true, word_tags: true, stdsub: nil
      subtitle = Subtitle.from_whisper_verbose_json(JSON.parse(JSON.generate(verbose_json)))
      use_norm = stdsub.nil? ? normalize : stdsub
      subtitle.merge_adjacent! if use_norm
      subtitle.to_srt(word_tags: word_tags)
    end

    protected

    def transcribe_with_params path, format:, merge_words:, language: nil, detect_lang: :simple, **extra
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

      if format.to_s.index('json')
        parsed   = JSON.parse(out)
        subtitle = Subtitle.from_whisper_verbose_json(parsed)
        merge_split_words!(subtitle) if merge_words
        out = SymMash.new(subtitle.to_whisper_verbose_hash)
      end

      lang = detect_language(out, detect_lang) if out.is_a?(Hash) && out.language

      SymMash.new output: out, lang: lang
    end

    def detect_language out, mode
      return nil unless out.is_a?(Hash) && out.language
      raw = out.language.to_s.strip
      case mode
      when :full
        entry = ISO_639.find_by_code(raw) || ISO_639.find_by_english_name(raw.capitalize)
        entry&.alpha2
      when :simple
        ISO_639.find_by_english_name(raw.capitalize)&.alpha2
      end
    end

    # Delegate to centralized VTT converter
    def vtt_convert verbose_json, normalize: true, word_tags: true, stdsub: nil
      subtitle = Subtitle.from_whisper_verbose_json(JSON.parse(JSON.generate(verbose_json)))
      use_norm = stdsub.nil? ? normalize : stdsub
      if use_norm
        subtitle.split_long_entries!(max_chars: Subtitler::Translator::MAX_SUBTITLE_CHARS)
        subtitle.merge_adjacent!(max_chars: Subtitler::Translator::MAX_SUBTITLE_CHARS)
      end
      subtitle.to_vtt(word_tags: word_tags)
    end

    # Translate using sentence-aware regrouping handled by Subtitler::Translator
    def translate verbose_json, from:, to:
      Subtitler::Translator.translate verbose_json, from: from, to: to
    end

    private

    def merge_split_words!(subtitle)
      raise TypeError, 'subtitle must be a Subtitler::Subtitle' unless subtitle.is_a?(Subtitle)

      subtitle.merge_split_words!
    end
  end
end
