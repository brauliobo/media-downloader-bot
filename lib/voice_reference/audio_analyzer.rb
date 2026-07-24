require 'tmpdir'

require_relative '../utils/sh'
require_relative '../zipper'

class VoiceReference
  class AudioAnalyzer
    SILENCE_THRESHOLD_DB = -35
    MAX_SILENCE_RATIO    = 0.1
    MAX_LOUDNESS_RANGE   = 6.0
    LOUDNESS_RANGE       = -22.0..-14.0
    MAX_TRUE_PEAK_DB     = -1.5
    MAX_PEAK_DB          = -1.0
    RMS_RANGE            = -35.0..-10.0
    MIN_ENTROPY          = 0.6
    MAX_ZERO_CROSSING    = 0.12
    MIN_BIT_DEPTH        = 14

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
      filter = [
        Zipper::VOICE_QUALITY_FILTER,
        "afade=t=in:st=0:d=0.03,afade=t=out:st=#{fade_out}:d=0.05"
      ].join(',')
      command = ffmpeg_extract(candidate, output) + ['-af', filter, '-c:a', 'pcm_s16le', output]
      run(command, 'voice reference extraction failed', output: output)
    end

    def report(path)
      signal    = metrics(path)
      loudness  = loudness_metrics(path)
      duration  = duration(path)
      silence   = silence_duration(path)
      report = signal.merge(
        duration:          duration,
        integrated_lufs:   loudness.fetch(:integrated_lufs),
        loudness_range_lu: loudness.fetch(:loudness_range_lu),
        true_peak_db:      loudness.fetch(:true_peak_db),
        silence_seconds:   silence,
        silence_ratio:     duration.positive? ? silence / duration : 1.0
      )
      report[:accepted] = acceptable?(signal) &&
        LOUDNESS_RANGE.cover?(report[:integrated_lufs]) &&
        report[:loudness_range_lu] <= MAX_LOUDNESS_RANGE &&
        report[:true_peak_db] <= MAX_TRUE_PEAK_DB &&
        report[:silence_ratio] <= MAX_SILENCE_RATIO
      report[:thresholds] = {
        min_integrated_lufs:  LOUDNESS_RANGE.min,
        max_integrated_lufs:  LOUDNESS_RANGE.max,
        max_loudness_range:   MAX_LOUDNESS_RANGE,
        max_true_peak_db:     MAX_TRUE_PEAK_DB,
        max_silence_ratio:    MAX_SILENCE_RATIO,
        max_peak_db:          MAX_PEAK_DB,
        min_rms_db:           RMS_RANGE.min,
        max_rms_db:           RMS_RANGE.max,
        min_entropy:          MIN_ENTROPY,
        max_zero_crossing:    MAX_ZERO_CROSSING,
        min_bit_depth:        MIN_BIT_DEPTH
      }
      report
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

    def loudness_metrics(path)
      command = [
        'ffmpeg', '-hide_banner', '-nostats', '-i', path,
        '-af', 'ebur128=peak=true', '-f', 'null', '-'
      ]
      _, stderr, status = Sh.run(command)
      Sh.assert_success!('voice reference loudness analysis failed', stderr, status: status)
      summary = stderr.split('Summary:').last.to_s
      {
        integrated_lufs:   metric(summary, 'I'),
        loudness_range_lu: metric(summary, 'LRA'),
        true_peak_db:      metric(summary, 'Peak')
      }
    end

    def duration(path)
      command = [
        'ffprobe', '-v', 'error', '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1', path
      ]
      stdout, stderr, status = Sh.run(command)
      Sh.assert_success!('voice reference duration analysis failed', stderr, status: status)
      stdout.to_f
    end

    def silence_duration(path)
      command = [
        'ffmpeg', '-hide_banner', '-nostats', '-i', path,
        '-af', "silencedetect=noise=#{SILENCE_THRESHOLD_DB}dB:d=0.08", '-f', 'null', '-'
      ]
      _, stderr, status = Sh.run(command)
      Sh.assert_success!('voice reference silence analysis failed', stderr, status: status)
      stderr.scan(/silence_duration: (\d+(?:\.\d+)?)/).flatten.sum(&:to_f)
    end

    def acceptable?(metrics)
      metrics[:peak_db] <= MAX_PEAK_DB &&
        RMS_RANGE.cover?(metrics[:rms_db]) &&
        metrics[:entropy] >= MIN_ENTROPY &&
        metrics[:zero_crossing_rate] <= MAX_ZERO_CROSSING &&
        metrics[:bit_depth] >= MIN_BIT_DEPTH
    end

    def signal_score(metrics)
      metrics[:entropy] - metrics[:zero_crossing_rate] * 2 - (metrics[:rms_db] + 20).abs / 20
    end

    def metric(output, name)
      output.scan(/#{Regexp.escape(name)}:\s+(-?\d+(?:\.\d+)?)/).flatten.last.to_f
    end

    def run(command, label, output: nil)
      _, stderr, status = Sh.run(command)
      Sh.assert_success!(label, stderr, status: status, output: output)
    end
  end
end
