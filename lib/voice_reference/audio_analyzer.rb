require 'tmpdir'

require_relative '../audio'
require_relative '../zipper'

class VoiceReference
  class AudioAnalyzer
    def initialize(quality: Audio::Quality.new)
      @quality = quality
    end

    def assess(candidate)
      Dir.mktmpdir('voice-reference-') do |dir|
        clip = File.join(dir, 'candidate.wav')
        extract_raw(candidate, clip)
        metrics = quality.signal(clip)
        return unless quality.signal_acceptable?(metrics)

        candidate.metrics = metrics
        candidate.score   = signal_score(metrics) + candidate.confidence * 0.2
        candidate
      end
    end

    def extract(candidate, output)
      fade_out = [candidate.duration - 0.05, 0].max
      filter = [
        Zipper::VOICE_QUALITY_FILTER,
        "afade=t=in:st=0:d=0.03,afade=t=out:st=#{fade_out}:d=0.05"
      ].join(',')
      command = ffmpeg_extract(candidate, output) + ['-af', filter, '-c:a', 'pcm_s16le', output]
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

    def signal_score(metrics)
      metrics[:entropy] - metrics[:zero_crossing_rate] * 2 - (metrics[:rms_db] + 20).abs / 20
    end

    def run(command, label, output: nil)
      _, stderr, status = Sh.run(command)
      Sh.assert_success!(label, stderr, status: status, output: output)
    end
  end
end
