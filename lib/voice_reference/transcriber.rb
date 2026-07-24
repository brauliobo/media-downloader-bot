require 'fileutils'
require 'json'

require_relative '../subtitler'

class VoiceReference
  class Transcriber
    def initialize(backend: Subtitler, cache_dir: nil)
      @backend   = backend
      @cache_dir = File.expand_path(cache_dir) if cache_dir
      FileUtils.mkdir_p(@cache_dir) if @cache_dir
    end

    def call(audio)
      cache = cache_path(audio)
      return JSON.parse(File.read(cache), symbolize_names: true) if cache && File.exist?(cache)

      result = backend.transcribe(audio, format: 'verbose_json', merge_words: false)
      transcript = normalize(result)
      File.write(cache, JSON.pretty_generate(transcript)) if cache
      transcript
    end

    private

    attr_reader :backend, :cache_dir

    def normalize(result)
      output = result.output
      {
        language: result.lang || Subtitler.normalize_lang(output.language),
        segments: Array(output.segments).map { |segment| normalize_segment(segment) }
      }
    end

    def normalize_segment(segment)
      probabilities = Array(segment.words).filter_map do |word|
        value = word.probability || word.probability_score || word.prob
        value.to_f if value
      end
      if probabilities.empty? && segment.avg_logprob
        probabilities = Array.new(segment.text.to_s.scan(/[[:alpha:]]+/).size, Math.exp(segment.avg_logprob.to_f))
      end
      {
        start:         segment.start.to_f,
        finish:        segment.end.to_f,
        text:          segment.text.to_s.strip,
        probabilities: probabilities
      }
    end

    def cache_path(audio)
      return unless cache_dir

      File.join(cache_dir, "#{File.basename(audio, File.extname(audio))}.json")
    end
  end
end
