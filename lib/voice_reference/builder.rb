require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'

class VoiceReference
  class Builder
    MAX_VALIDATION_CANDIDATES = 20
    MIN_TRANSCRIPT_SIMILARITY = 0.8
    MIN_AVERAGE_PROBABILITY   = 0.85
    MIN_P10_PROBABILITY       = 0.75

    def initialize(transcriber: Transcriber.new, selector: Selector.new, analyzer: AudioAnalyzer.new, language: 'en', reference_filter: :raw)
      @transcriber      = transcriber
      @selector         = selector
      @analyzer         = analyzer
      @language         = language
      @reference_filter = reference_filter
    end

    def build(audio_files:, output:)
      recordings = Array(audio_files).map do |audio|
        {audio: audio, transcript: transcriber.call(audio)}
      end
      candidate = validated_candidate(selector.rank(recordings), output)
      raise 'no voice reference candidate passed quality checks' unless candidate

      text_path   = sidecar(output, '.txt')
      report_path = sidecar(output, '.json')
      File.write(text_path, "#{candidate.text}\n")
      candidate.artifacts = {
        audio:      artifact(output),
        transcript: artifact(text_path),
        report:     {path: report_path}
      }
      File.write(report_path, JSON.pretty_generate(candidate.to_h))
      candidate
    end

    private

    attr_reader :transcriber, :selector, :analyzer, :language, :reference_filter

    def sidecar(output, extension)
      output.sub(/\.[^.]+\z/, extension)
    end

    def validated_candidate(candidates, output)
      Dir.mktmpdir('voice-reference-validation-') do |dir|
        Array(candidates).first(MAX_VALIDATION_CANDIDATES).each_with_index do |candidate, index|
          path = File.join(dir, "#{candidate_key(candidate)}.wav")
          analyzer.extract(candidate, path, filter: reference_filter)
          validation = validation_report(
            candidate.text, transcriber.call(path), analyzer.report(path), reference_filter: reference_filter
          )
          next unless validation.fetch(:accepted)

          validation[:selection] = {rank: index + 1, rejected_candidates: index}
          candidate.text       = validation.dig(:transcript, :observed)
          candidate.validation = validation
          FileUtils.cp(path, output)
          return candidate
        end
      end
      nil
    end

    def candidate_key(candidate)
      Digest::SHA256.hexdigest([candidate.audio, candidate.start, candidate.finish].join(':'))
    end

    def artifact(path)
      {path: path, bytes: File.size(path), sha256: Digest::SHA256.file(path).hexdigest}
    end

    def validation_report(expected, transcript, audio, reference_filter: :clone)
      segments      = transcript.fetch(:segments)
      probabilities = segments.flat_map { |segment| segment.fetch(:probabilities) }
      average       = probabilities.empty? ? 0 : probabilities.sum.fdiv(probabilities.size)
      p10           = probabilities.empty? ? 0 : probabilities.sort[(probabilities.size * 0.1).floor]
      observed      = segments.map { |segment| segment.fetch(:text) }.join(' ')
      similarity    = word_similarity(expected, observed)
      transcript_ok = transcript.fetch(:language) == language &&
        average >= MIN_AVERAGE_PROBABILITY && p10 >= MIN_P10_PROBABILITY &&
        similarity >= MIN_TRANSCRIPT_SIMILARITY
      {
        accepted: audio.fetch(:accepted) && transcript_ok,
        tools: Audio::Quality::TOOLS.merge(transcription: 'Subtitler::WhisperCpp'),
        voice_quality_filter: AudioAnalyzer::FILTERS.fetch(reference_filter),
        transcript: {
          accepted:            transcript_ok,
          language:            transcript.fetch(:language),
          expected:            expected,
          observed:            observed,
          similarity:          similarity,
          average_probability: average,
          p10_probability:     p10,
          thresholds: {
            min_similarity:          MIN_TRANSCRIPT_SIMILARITY,
            min_average_probability: MIN_AVERAGE_PROBABILITY,
            min_p10_probability:     MIN_P10_PROBABILITY
          }
        },
        audio: audio
      }
    end

    def word_similarity(expected, observed)
      left  = expected.downcase.scan(/[[:alpha:]]+/)
      right = observed.downcase.scan(/[[:alpha:]]+/)
      return 0 if left.empty? || right.empty?

      previous = Array.new(right.size + 1, 0)
      left.each do |word|
        current = [0]
        right.each_with_index do |other, index|
          current << if word == other
            previous[index] + 1
          else
            [previous[index + 1], current[index]].max
          end
        end
        previous = current
      end
      previous.last.fdiv([left.size, right.size].max)
    end
  end
end
