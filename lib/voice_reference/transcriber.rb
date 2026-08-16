require 'fileutils'
require 'json'
require 'digest'

require_relative '../subtitler'

class VoiceReference
  class Transcriber
    CACHE_VERSION = 1

    def initialize(backend: Subtitler, cache_dir: nil, separate_voice: true)
      @backend        = backend
      @cache_dir      = File.expand_path(cache_dir) if cache_dir
      @separate_voice = separate_voice
      FileUtils.mkdir_p(@cache_dir) if @cache_dir
    end

    def call(audio, cache_key: nil, separate_voice: self.separate_voice)
      cache = cache_path(audio, cache_key)
      if cache && File.exist?(cache)
        cached = read_cache(cache)
        return cached if cached
      end

      options = {merge_words: false}
      options[:separate_voice] = false unless separate_voice
      subtitle = backend.transcribe(audio, **options)
      raise TypeError, 'transcription must be a Subtitler::Subtitle' unless subtitle.is_a?(Subtitler::Subtitle)

      File.write(cache, JSON.pretty_generate(cache_payload(subtitle))) if cache
      subtitle
    end

    private

    attr_reader :backend, :cache_dir, :separate_voice

    def read_cache(path)
      payload = JSON.parse(File.read(path))
      if legacy_cache?(payload)
        FileUtils.rm(path)
        return
      end

      version = payload.fetch('version') do
        raise ArgumentError, 'voice reference transcript cache is missing a version'
      end
      unless version == CACHE_VERSION
        raise ArgumentError, "unsupported voice reference transcript cache version: #{version.inspect}"
      end

      subtitle_from_cache(payload.fetch('subtitle'))
    end

    def legacy_cache?(payload)
      payload.is_a?(Hash) && !payload.key?('version') && payload.key?('language') && payload.key?('segments')
    end

    def cache_payload(subtitle)
      {
        version:  CACHE_VERSION,
        subtitle: {
          language: subtitle.language,
          text:     subtitle.text,
          entries:  subtitle.entries.map { |entry| cache_entry(entry) },
          metadata: subtitle.metadata
        }
      }
    end

    def cache_entry(entry)
      {
        start:        entry.start,
        finish:       entry.finish,
        text:         entry.text,
        words:        entry.words.map { |word| cache_word(word) },
        speaker_id:   entry.speaker_id,
        cue_id:       entry.cue_id,
        source_text:  entry.source_text,
        source_words: entry.source_words.map { |word| cache_word(word) },
        metadata:     entry.metadata
      }
    end

    def cache_word(word)
      {
        text:       word.text,
        start:      word.start,
        finish:     word.finish,
        confidence: word.confidence,
        metadata:   word.metadata
      }
    end

    def subtitle_from_cache(data)
      Subtitler::Subtitle.new(
        language: data.fetch('language'),
        text:     data.fetch('text'),
        entries:  data.fetch('entries').map { |entry| entry_from_cache(entry) },
        metadata: data.fetch('metadata')
      )
    end

    def entry_from_cache(data)
      Subtitler::Subtitle::Entry.new(
        start:        data.fetch('start'),
        finish:       data.fetch('finish'),
        text:         data.fetch('text'),
        words:        data.fetch('words').map { |word| word_from_cache(word) },
        speaker_id:   data.fetch('speaker_id'),
        cue_id:       data.fetch('cue_id'),
        source_text:  data.fetch('source_text'),
        source_words: data.fetch('source_words').map { |word| word_from_cache(word) },
        metadata:     data.fetch('metadata')
      )
    end

    def word_from_cache(data)
      Subtitler::Subtitle::Word.new(
        text:       data.fetch('text'),
        start:      data.fetch('start'),
        finish:     data.fetch('finish'),
        confidence: data.fetch('confidence'),
        metadata:   data.fetch('metadata')
      )
    end

    def cache_path(audio, cache_key)
      return unless cache_dir

      name = if cache_key
        Digest::SHA256.hexdigest(cache_key.to_s)
      else
        File.basename(audio, File.extname(audio))
      end
      File.join(cache_dir, "#{name}.json")
    end
  end
end
