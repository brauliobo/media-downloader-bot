require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'

require_relative '../ffmpeg'
require_relative 'transcript_quality'

class VoiceReference
  class Builder
    MAX_VALIDATION_CANDIDATES = 20
    MIN_TRANSCRIPT_SIMILARITY = 0.8
    MIN_AVERAGE_PROBABILITY   = 0.85
    MIN_P10_PROBABILITY       = 0.75

    def initialize(
      transcriber: Transcriber.new, selector: Selector.new, analyzer: AudioAnalyzer.new, language: 'en',
      reference_filter: :raw, on_status: nil
    )
      @transcriber      = transcriber
      @selector         = selector
      @analyzer         = analyzer
      @language         = language
      @reference_filter = reference_filter
      @on_status        = on_status
    end

    def build(audio_files:, output:, transcripts: {}, source_files: nil)
      audio_files  = Array(audio_files)
      prepared     = !source_files.nil?
      source_files = source_files ? Array(source_files) : audio_files
      recordings = audio_files.zip(source_files).map do |audio, source|
        transcript = transcripts.fetch(source) do
          prepared ? transcriber.call(audio, cache_key: source, separate_voice: false) : transcriber.call(audio)
        end
        raise TypeError, 'transcript must be a Subtitler::Subtitle' unless transcript.is_a?(Subtitler::Subtitle)

        transcript = transcript.deep_copy.replace_language!(language) if transcript.language.blank?
        {audio: audio, transcript: transcript}
      end
      sources   = audio_files.zip(source_files).to_h
      candidate = validated_candidate(selector.rank(recordings), output, sources: sources, prepared: prepared)
      raise 'no voice reference candidate passed quality checks' unless candidate

      candidate.audio = sources.fetch(candidate.audio)
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

    attr_reader :transcriber, :selector, :analyzer, :language, :reference_filter, :on_status

    def sidecar(output, extension)
      output.sub(/\.[^.]+\z/, extension)
    end

    def validated_candidate(candidates, output, sources:, prepared:)
      Dir.mktmpdir('voice-reference-validation-') do |dir|
        selected = Array(candidates).first(MAX_VALIDATION_CANDIDATES)
        selected.each_with_index do |candidate, index|
          on_status&.call("Validating voice reference #{index + 1}/#{selected.size}")
          key  = candidate_key(candidate, sources.fetch(candidate.audio))
          path = File.join(dir, "#{key}.wav")
          analyzer.extract(candidate, path, filter: reference_filter)
          transcript = if prepared
            transcriber.call(path, cache_key: "validation:#{reference_filter}:#{key}", separate_voice: false)
          else
            transcriber.call(path)
          end
          validation = validation_report(
            candidate.text, transcript, analyzer.report(path), reference_filter: reference_filter
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

    def candidate_key(candidate, source)
      Digest::SHA256.hexdigest([source, candidate.start, candidate.finish].join(':'))
    end

    def artifact(path)
      {path: path, bytes: File.size(path), sha256: Digest::SHA256.file(path).hexdigest}
    end

    def validation_report(expected, transcript, audio, reference_filter: :clone)
      raise TypeError, 'transcript must be a Subtitler::Subtitle' unless transcript.is_a?(Subtitler::Subtitle)

      probabilities = transcript.entries.flat_map { |entry| TranscriptQuality.word_confidences(entry) }
      average       = probabilities.empty? ? 0 : probabilities.sum.fdiv(probabilities.size)
      p10           = probabilities.empty? ? 0 : probabilities.sort[(probabilities.size * 0.1).floor]
      observed      = transcript.entries.map(&:text).join(' ')
      similarity    = VoiceReference::TranscriptQuality.word_similarity(expected, observed)
      transcript_language = transcript.language.presence || language
      transcript_ok = transcript_language == language &&
        average >= MIN_AVERAGE_PROBABILITY && p10 >= MIN_P10_PROBABILITY &&
        similarity >= MIN_TRANSCRIPT_SIMILARITY
      {
        accepted: audio.fetch(:accepted) && transcript_ok,
        tools: FFmpeg::TOOLS.merge(transcription: 'Subtitler::WhisperCpp'),
        voice_quality_filter: AudioAnalyzer::FILTERS.fetch(reference_filter),
        transcript: {
          accepted:            transcript_ok,
          language:            transcript_language,
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

  end
end
