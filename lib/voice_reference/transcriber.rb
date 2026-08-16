require 'fileutils'
require 'json'
require 'digest'

require_relative '../subtitler'

class VoiceReference
  class Transcriber
    def initialize(backend: Subtitler, cache_dir: nil, separate_voice: true)
      @backend        = backend
      @cache_dir      = File.expand_path(cache_dir) if cache_dir
      @separate_voice = separate_voice
      FileUtils.mkdir_p(@cache_dir) if @cache_dir
    end

    def call(audio, cache_key: nil, separate_voice: self.separate_voice)
      cache = cache_path(audio, cache_key)
      return JSON.parse(File.read(cache), symbolize_names: true) if cache && File.exist?(cache)

      options = {format: 'verbose_json', merge_words: false}
      options[:separate_voice] = false unless separate_voice
      subtitle = backend.transcribe(audio, **options)
      transcript = normalize(subtitle)
      File.write(cache, JSON.pretty_generate(transcript)) if cache
      transcript
    end

    private

    attr_reader :backend, :cache_dir, :separate_voice

    def normalize(subtitle)
      raise TypeError, 'transcription must be a Subtitler::Subtitle' unless subtitle.is_a?(Subtitler::Subtitle)

      {
        language: subtitle.language,
        segments: subtitle.entries.map { |segment| normalize_segment(segment) }
      }
    end

    def normalize_segment(segment)
      probabilities = segment.words.filter_map(&:confidence)
      if probabilities.empty? && segment.metadata['avg_logprob']
        probabilities = Array.new(segment.text.scan(/[[:alpha:]]+/).size, Math.exp(segment.metadata['avg_logprob'].to_f))
      end
      {
        start:         segment.start.to_f,
        finish:        segment.finish.to_f,
        text:          segment.text.strip,
        probabilities: probabilities
      }
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
