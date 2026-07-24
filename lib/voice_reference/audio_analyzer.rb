require 'tmpdir'

require_relative '../utils/sh'

class VoiceReference
  class AudioAnalyzer
    def assess(candidate)
      Dir.mktmpdir('voice-reference-') do |dir|
        clip = File.join(dir, 'candidate.wav')
        extract_raw(candidate, clip)
        metrics = metrics(clip)
        return unless acceptable?(metrics)

        candidate.metrics = metrics
        candidate.score   = signal_score(metrics) + candidate.confidence * 0.2
        candidate
      end
    end

    def extract(candidate, output)
      fade_out = [candidate.duration - 0.05, 0].max
      filter = "highpass=f=65,lowpass=f=11500,afade=t=in:st=0:d=0.03,afade=t=out:st=#{fade_out}:d=0.05"
      command = ffmpeg_extract(candidate, output) + ['-af', filter, '-c:a', 'pcm_s16le', output]
      run(command, 'voice reference extraction failed', output: output)
    end

    private

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

    def metrics(path)
      command = [
        'ffmpeg', '-hide_banner', '-nostats', '-i', path,
        '-af', 'astats=metadata=0:reset=0', '-f', 'null', '-'
      ]
      _, stderr, status = Sh.run(command)
      Sh.assert_success!('voice candidate analysis failed', stderr, status: status)
      {
        peak_db:            metric(stderr, 'Peak level dB'),
        rms_db:             metric(stderr, 'RMS level dB'),
        entropy:            metric(stderr, 'Entropy'),
        zero_crossing_rate: metric(stderr, 'Zero crossings rate'),
        bit_depth:          stderr.scan(/Bit depth: (\d+)/).flatten.last.to_i
      }
    end

    def acceptable?(metrics)
      metrics[:peak_db] <= -1.0 &&
        metrics[:rms_db].between?(-35.0, -10.0) &&
        metrics[:entropy] >= 0.6 &&
        metrics[:zero_crossing_rate] <= 0.12 &&
        metrics[:bit_depth] >= 14
    end

    def signal_score(metrics)
      metrics[:entropy] - metrics[:zero_crossing_rate] * 2 - (metrics[:rms_db] + 20).abs / 20
    end

    def metric(output, name)
      output.scan(/#{Regexp.escape(name)}: (-?\d+(?:\.\d+)?)/).flatten.last.to_f
    end

    def run(command, label, output: nil)
      _, stderr, status = Sh.run(command)
      Sh.assert_success!(label, stderr, status: status, output: output)
    end
  end
end
