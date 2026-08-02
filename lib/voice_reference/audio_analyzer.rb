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

    def extract(candidate, output)
      command = ffmpeg_extract(candidate, output) + ['-af', REFERENCE_FILTER, '-c:a', 'pcm_s16le', output]
      run(command, 'voice reference extraction failed', output: output)
    end

    def report(path)
      quality.report(path)
    end

    private

    attr_reader :quality

    def extract_raw(candidate, output)
      command = ffmpeg_extract(candidate, output) + ['-c:a', 'pcm_s16le', output]
      run(command, 'voice candidate extraction failed', output: output)
    end

    def ffmpeg_extract(candidate, _output)
      [
        'ffmpeg', '-loglevel', 'error', '-y', '-ss', candidate.start.to_s,
        '-t', candidate.duration.to_s, '-i', candidate.audio, '-vn',
        '-ac', '1', '-ar', '24000'
      ]
    end

    def run(command, label, output: nil)
      _, stderr, status = Sh.run(command)
      Sh.assert_success!(label, stderr, status: status, output: output)
    end
  end
end
