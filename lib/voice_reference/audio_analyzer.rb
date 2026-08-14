require 'tmpdir'

require_relative '../audio'
require_relative '../ffmpeg'

class VoiceReference
  class AudioAnalyzer
    SILENCE_THRESHOLD_DB = Audio::Quality::DEFAULT_THRESHOLDS.fetch(:silence_threshold_db)
    FILTERS = {
      raw:     FFmpeg.voice_reference_filter(:raw, silence_threshold_db: SILENCE_THRESHOLD_DB),
      clone:   FFmpeg.voice_reference_filter(:clone, silence_threshold_db: SILENCE_THRESHOLD_DB),
      quality: FFmpeg.voice_reference_filter(:quality, silence_threshold_db: SILENCE_THRESHOLD_DB),
    }.freeze

    def initialize quality: Audio::Quality.new, ffmpeg: nil
      @quality = quality
      @ffmpeg  = ffmpeg || FFmpeg.new
    end

    def assess(candidate)
      candidate = measure(candidate)
      candidate if quality.signal_acceptable?(candidate.metrics)
    end

    def measure(candidate)
      Dir.mktmpdir('voice-reference-') do |dir|
        clip = File.join(dir, 'candidate.wav')
        extract_raw(candidate, clip)
        metrics = quality.signal(clip)
        candidate.metrics = metrics
        candidate.score   = Audio::ReferenceQuality.signal_score(metrics) + candidate.confidence * 0.2
        candidate
      end
    end

    def extract(candidate, output, filter: :raw)
      extract_span(
        audio:    candidate.audio,
        start:    candidate.start,
        duration: candidate.duration,
        output:   output,
        filter:   filter
      )
    end

    def extract_span(audio:, start:, duration:, output:, sample_rate: 24_000, pad_duration: nil, filter: :raw)
      filter_chain = if filter.is_a? Symbol
        resolve_filter filter, pad_duration: pad_duration
      else
        pad_filter = FFmpeg.voice_reference_filter(
          :raw, silence_threshold_db: SILENCE_THRESHOLD_DB, pad_duration: pad_duration
        )
        [filter, pad_filter].compact.join ','
      end
      filter_chain = nil if filter_chain&.empty?
      ffmpeg.extract_audio(
        input:       audio,
        output:      output,
        start:       start,
        duration:    duration,
        filter:      filter_chain,
        sample_rate: sample_rate,
        channels:    1,
        label:       'voice reference extraction failed'
      )
    end

    def report(path)
      quality.report(path)
    end

    private

    attr_reader :quality, :ffmpeg

    def extract_raw(candidate, output)
      ffmpeg.extract_audio(
        input:       candidate.audio,
        output:      output,
        start:       candidate.start,
        duration:    candidate.duration,
        filter:      nil,
        sample_rate: 24_000,
        channels:    1,
        label:       'voice candidate extraction failed'
      )
    end

    def resolve_filter filter, pad_duration: nil
      FILTERS.fetch filter
      FFmpeg.voice_reference_filter(
        filter, silence_threshold_db: SILENCE_THRESHOLD_DB, pad_duration: pad_duration
      )
    end
  end
end
