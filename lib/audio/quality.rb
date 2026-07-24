require_relative '../utils/sh'

module Audio
end

class Audio::Quality
  TOOLS = {
    signal:   'ffmpeg astats',
    loudness: 'ffmpeg ebur128',
    silence:  'ffmpeg silencedetect'
  }.freeze

  DEFAULT_THRESHOLDS = {
    silence_threshold_db: -35,
    max_silence_ratio:    0.1,
    max_loudness_range:   6.0,
    integrated_lufs:      -22.0..-14.0,
    max_true_peak_db:     -1.5,
    max_peak_db:          -1.0,
    rms_db:               -35.0..-10.0,
    min_entropy:          0.6,
    max_zero_crossing:    0.12,
    min_bit_depth:        14
  }.freeze

  def initialize(thresholds: {})
    @thresholds = DEFAULT_THRESHOLDS.merge(thresholds)
  end

  def signal(path)
    command = [
      'ffmpeg', '-hide_banner', '-nostats', '-i', path,
      '-af', 'astats=metadata=0:reset=0', '-f', 'null', '-'
    ]
    _, stderr, status = Sh.run(command)
    Sh.assert_success!('audio signal analysis failed', stderr, status: status)
    {
      peak_db:            metric(stderr, 'Peak level dB'),
      rms_db:             metric(stderr, 'RMS level dB'),
      entropy:            metric(stderr, 'Entropy'),
      zero_crossing_rate: metric(stderr, 'Zero crossings rate'),
      bit_depth:          stderr.scan(/Bit depth: (\d+)/).flatten.last.to_i
    }
  end

  def report(path)
    signal_metrics = signal(path)
    loudness       = loudness(path)
    seconds        = duration(path)
    silence        = silence_duration(path)
    report = signal_metrics.merge(
      duration:          seconds,
      integrated_lufs:   loudness.fetch(:integrated_lufs),
      loudness_range_lu: loudness.fetch(:loudness_range_lu),
      true_peak_db:      loudness.fetch(:true_peak_db),
      silence_seconds:   silence,
      silence_ratio:     seconds.positive? ? silence / seconds : 1.0
    )
    report[:accepted]   = acceptable?(report)
    report[:thresholds] = reported_thresholds
    report
  end

  def signal_acceptable?(metrics)
    metrics[:peak_db] <= thresholds.fetch(:max_peak_db) &&
      thresholds.fetch(:rms_db).cover?(metrics[:rms_db]) &&
      metrics[:entropy] >= thresholds.fetch(:min_entropy) &&
      metrics[:zero_crossing_rate] <= thresholds.fetch(:max_zero_crossing) &&
      metrics[:bit_depth] >= thresholds.fetch(:min_bit_depth)
  end

  private

  attr_reader :thresholds

  def loudness(path)
    command = [
      'ffmpeg', '-hide_banner', '-nostats', '-i', path,
      '-af', 'ebur128=peak=true', '-f', 'null', '-'
    ]
    _, stderr, status = Sh.run(command)
    Sh.assert_success!('audio loudness analysis failed', stderr, status: status)
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
    Sh.assert_success!('audio duration analysis failed', stderr, status: status)
    stdout.to_f
  end

  def silence_duration(path)
    command = [
      'ffmpeg', '-hide_banner', '-nostats', '-i', path,
      '-af', "silencedetect=noise=#{thresholds.fetch(:silence_threshold_db)}dB:d=0.08", '-f', 'null', '-'
    ]
    _, stderr, status = Sh.run(command)
    Sh.assert_success!('audio silence analysis failed', stderr, status: status)
    stderr.scan(/silence_duration: (\d+(?:\.\d+)?)/).flatten.sum(&:to_f)
  end

  def acceptable?(report)
    signal_acceptable?(report) &&
      thresholds.fetch(:integrated_lufs).cover?(report[:integrated_lufs]) &&
      report[:loudness_range_lu] <= thresholds.fetch(:max_loudness_range) &&
      report[:true_peak_db] <= thresholds.fetch(:max_true_peak_db) &&
      report[:silence_ratio] <= thresholds.fetch(:max_silence_ratio)
  end

  def reported_thresholds
    {
      silence_threshold_db: thresholds.fetch(:silence_threshold_db),
      max_silence_ratio:    thresholds.fetch(:max_silence_ratio),
      max_loudness_range:   thresholds.fetch(:max_loudness_range),
      min_integrated_lufs:  thresholds.fetch(:integrated_lufs).min,
      max_integrated_lufs:  thresholds.fetch(:integrated_lufs).max,
      max_true_peak_db:     thresholds.fetch(:max_true_peak_db),
      max_peak_db:          thresholds.fetch(:max_peak_db),
      min_rms_db:           thresholds.fetch(:rms_db).min,
      max_rms_db:           thresholds.fetch(:rms_db).max,
      min_entropy:          thresholds.fetch(:min_entropy),
      max_zero_crossing:    thresholds.fetch(:max_zero_crossing),
      min_bit_depth:        thresholds.fetch(:min_bit_depth)
    }
  end

  def metric(output, name)
    output.scan(/#{Regexp.escape(name)}:\s+(-?\d+(?:\.\d+)?)/).flatten.last.to_f
  end
end
