require 'tmpdir'

require_relative '../audio'
require_relative '../zipper'

class VoiceReference
  class AudioAnalyzer
    SILENCE_THRESHOLD_DB = Audio::Quality::DEFAULT_THRESHOLDS.fetch(:silence_threshold_db)
    EDGE_FILTER = [
      "silenceremove=start_periods=1:start_duration=0.1:start_threshold=#{SILENCE_THRESHOLD_DB}dB:start_silence=0.05",
      'areverse',
      "silenceremove=start_periods=1:start_duration=0.1:start_threshold=#{SILENCE_THRESHOLD_DB}dB:start_silence=0.05",
      'afade=t=in:st=0:d=0.05',
      'areverse',
      'afade=t=in:st=0:d=0.03'
    ].join(',').freeze
    REFERENCE_FILTER = [Zipper::VOICE_QUALITY_FILTER, EDGE_FILTER].join(',').freeze
    CLONE_REFERENCE_FILTER = [
      'highpass=f=80',
      'afftdn=nf=-25',
      'loudnorm=I=-16:TP=-1.5:LRA=11'
    ].join(',').freeze
    FILTERS = {
      raw:     nil,
      clone:   CLONE_REFERENCE_FILTER,
      quality: REFERENCE_FILTER,
    }.freeze

    def initialize(quality: Audio::Quality.new)
      @quality = quality
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
      filter_chain = [resolve_filter(filter), ("apad=pad_dur=#{pad_duration}" if pad_duration)].compact.join(',')
      command = ffmpeg_extract(audio, start, duration) + [
        *(['-af', filter_chain] unless filter_chain.empty?),
        '-ac', '1', '-ar', sample_rate.to_i.to_s, '-c:a', 'pcm_s16le', output
      ]
      run(command, 'voice reference extraction failed', output: output)
    end

    def report(path)
      quality.report(path)
    end

    private

    attr_reader :quality

    def extract_raw(candidate, output)
      command = ffmpeg_extract(candidate.audio, candidate.start, candidate.duration) + [
        '-ac', '1', '-ar', '24000', '-c:a', 'pcm_s16le', output
      ]
      run(command, 'voice candidate extraction failed', output: output)
    end

    def ffmpeg_extract(audio, start, duration)
      [
        'ffmpeg', '-loglevel', 'error', '-y', '-ss', start.to_s,
        '-t', duration.to_s, '-i', audio, '-vn'
      ]
    end

    def resolve_filter(filter)
      filter.is_a?(Symbol) ? FILTERS.fetch(filter) : filter
    end

    def run(command, label, output: nil)
      _, stderr, status = Sh.run(command)
      Sh.assert_success!(label, stderr, status: status, output: output)
    end
  end
end
