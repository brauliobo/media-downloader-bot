require 'csv'
require 'fileutils'
require 'json'
require 'time'

require_relative 'transcript_score'
require_relative 'embedding_scorer'

class VoiceClone
  class Case
    attr_reader :name, :parameters

    def initialize(name:, reference: false, parameters: {})
      @name       = name.to_s
      @reference  = !!reference
      @parameters = (parameters || {}).to_h.transform_keys(&:to_sym).freeze
      raise ArgumentError, 'voice clone evaluation case name is empty' if @name.empty?
    end

    def use_reference?
      @reference
    end

    def to_h
      {name: name, reference: use_reference?, parameters: parameters.transform_keys(&:to_s)}
    end
  end

  class Evaluator
    DEFAULT = Object.new.freeze

    def initialize(
      output_dir:,
      synthesizer: nil,
      transcriber: DEFAULT,
      transcript_scorer: DEFAULT,
      embedding_scorer: DEFAULT,
      clock: -> { Time.now.utc },
      monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )
      @output_dir       = File.expand_path(output_dir)
      @synthesizer      = synthesizer || TTS::OmniVoice
      @transcriber      = transcriber.equal?(DEFAULT) ? VoiceReference::Transcriber.new : transcriber
      @transcript_scorer = transcript_scorer
      @embedding_scorer  = embedding_scorer.equal?(DEFAULT) ? VoiceClone::EmbeddingScorer.new : embedding_scorer
      @clock             = clock
      @monotonic_clock   = monotonic_clock
    end

    def run(text:, language:, cases:, reference_audio: nil, reference_text: nil, comparison_audio: reference_audio, repeats: 1)
      cases = Array(cases).map { |test_case| normalize_case(test_case) }
      validate!(cases, reference_audio, reference_text, repeats)
      reference_audio  = expand_paths(reference_audio)
      comparison_audio = expand_paths(comparison_audio || reference_audio)
      FileUtils.mkdir_p(File.join(@output_dir, 'audio'))

      report = {
        generated_at:     @clock.call.iso8601,
        language:         language.to_s,
        source_text:      text,
        reference_audio:  reference_audio,
        comparison_audio: comparison_audio,
        cases:            cases.map(&:to_h),
        repeats:          repeats.to_i,
        results:          cases.flat_map do |test_case|
          (1..repeats.to_i).map do |repeat|
            evaluate_case(
              test_case, repeat, text, language.to_s, reference_audio, reference_text, comparison_audio,
              transcript_scorer(language)
            )
          end
        end
      }
      write_report(report)
      report
    end

    private

    attr_reader :output_dir, :synthesizer, :transcriber, :transcript_scorer, :embedding_scorer, :clock, :monotonic_clock

    def normalize_case(test_case)
      return test_case if test_case.is_a?(Case)

      values = test_case.to_h
      Case.new(
        name:       values.fetch(:name) { values.fetch('name') },
        reference:  values.fetch(:reference, values.fetch('reference', false)),
        parameters: values.fetch(:parameters, values.fetch('parameters', {}))
      )
    end

    def validate!(cases, reference_audio, reference_text, repeats)
      raise ArgumentError, 'voice clone evaluation requires at least one case' if cases.empty?
      raise ArgumentError, 'voice clone evaluation case names must be unique' unless cases.map(&:name).uniq.size == cases.size
      raise ArgumentError, 'repeats must be positive' unless repeats.to_i.positive?
      return unless cases.any?(&:use_reference?)

      raise ArgumentError, 'reference audio is required for clone cases' if paths(reference_audio).empty?
      raise ArgumentError, 'reference text is required for clone cases' if reference_text.to_s.strip.empty?
    end

    def transcript_scorer(language)
      @transcript_scorer.equal?(DEFAULT) ? VoiceClone::TranscriptScore.new(language: language) : @transcript_scorer
    end

    def evaluate_case(test_case, repeat, text, language, reference_audio, reference_text, comparison_audio, transcript_scorer)
      output_path = File.join(output_dir, 'audio', "#{slug(test_case.name)}-#{repeat}.wav")
      started = monotonic_clock.call
      options = test_case.parameters.merge(text: text, lang: language, out_path: output_path)
      if test_case.use_reference?
        options[:speaker_wav] = Array(reference_audio).first
        options[:ref_text] = reference_text
      end
      synthesizer.synthesize(**options)
      raise "synthesizer did not create #{output_path}" unless File.file?(output_path) && File.size?(output_path)

      result = {
        case:              test_case.name,
        repeat:            repeat,
        success:           true,
        reference_used:    test_case.use_reference?,
        parameters:        test_case.parameters.transform_keys(&:to_s),
        audio_path:        output_path,
        synthesis_seconds: monotonic_clock.call - started,
      }
      if transcriber
        transcript = transcriber.call(output_path)
        result[:transcript] = transcript_scorer.call(expected: text, transcript: transcript)
      end
      if embedding_scorer && comparison_audio
        result[:speaker_similarity] = embedding_scorer.call(reference: comparison_audio, sample: output_path)
      end
      result
    rescue StandardError => error
      {
        case:           test_case.name,
        repeat:         repeat,
        success:        false,
        reference_used: test_case.use_reference?,
        parameters:     test_case.parameters.transform_keys(&:to_s),
        error:          "#{error.class}: #{error.message}",
      }
    end

    def write_report(report)
      results_path = File.join(output_dir, 'results.json')
      summary_path = File.join(output_dir, 'summary.csv')
      report[:artifacts] = {results: results_path, summary: summary_path}
      File.write(results_path, JSON.pretty_generate(report))
      CSV.open(summary_path, 'w') do |csv|
        csv << %w[case repeat success reference_used synthesis_seconds match_rate word_error_rate speaker_similarity audio_path error]
        report.fetch(:results).each do |result|
          csv << [
            result[:case], result[:repeat], result[:success], result[:reference_used], result[:synthesis_seconds],
            result.dig(:transcript, :match_rate), result.dig(:transcript, :word_error_rate),
            result.dig(:speaker_similarity, :cosine_similarity), result[:audio_path], result[:error]
          ]
        end
      end
    end

    def paths(value)
      Array(value).compact.map(&:to_s).reject(&:empty?)
    end

    def expand_paths(value)
      return if value.nil?

      values = paths(value).map { |path| File.expand_path(path) }
      value.is_a?(Array) ? values : values.first
    end

    def slug(value)
      slug = value.downcase.gsub(/[^a-z0-9._-]+/, '-').sub(/\A-+|-+\z/, '')
      slug.empty? ? 'case' : slug
    end
  end
end
