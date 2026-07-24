require_relative '../utils/sh'

module Audio
end

class Audio::Quality
  TOOLS = {
    signal:       'ffmpeg astats',
    frame_signal: 'ffmpeg astats metadata',
    loudness:     'ffmpeg ebur128',
    silence:      'ffmpeg silencedetect'
  }.freeze

  DEFAULT_THRESHOLDS = {
    silence_threshold_db:         -35,
    max_silence_ratio:            0.1,
    max_loudness_range:           6.0,
    integrated_lufs:              -22.0..-14.0,
    max_true_peak_db:             -1.5,
    max_peak_db:                  -1.0,
    rms_db:                       -35.0..-10.0,
    min_entropy:                  0.6,
    max_zero_crossing:            0.12,
    min_bit_depth:                14,
    max_estimated_noise_floor_db: -30.0,
    min_estimated_snr_db:         12.0,
    max_edge_rms_db:              -35.0
  }.freeze

  ANALYSIS_FLOOR_DB = -120.0

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
    frame_metrics  = frame_signal(path)
    loudness       = loudness(path)
    seconds        = duration(path)
    silence        = silence_duration(path)
    report = signal_metrics.merge(frame_metrics).merge(
      duration:          seconds,
      integrated_lufs:   loudness.fetch(:integrated_lufs),
      loudness_range_lu: loudness.fetch(:loudness_range_lu),
      true_peak_db:      loudness.fetch(:true_peak_db),
      silence_seconds:   silence,
      silence_ratio:     seconds.positive? ? silence / seconds : 1.0
    )
    report[:issues]     = diagnose(report)
    report[:accepted]   = report[:issues].none? { |issue| issue[:severity] == 'error' }
    report[:thresholds] = reported_thresholds
    report
  end

  def diagnose(metrics)
    issues = []
    issues << issue('peak_too_high', 'peak_db', metrics[:peak_db], {maximum: thresholds.fetch(:max_peak_db)}) if
      metrics[:peak_db] > thresholds.fetch(:max_peak_db)
    issues << issue('rms_out_of_range', 'rms_db', metrics[:rms_db], range_threshold(thresholds.fetch(:rms_db))) unless
      thresholds.fetch(:rms_db).cover?(metrics[:rms_db])
    issues << issue('low_entropy', 'entropy', metrics[:entropy], {minimum: thresholds.fetch(:min_entropy)}) if
      metrics[:entropy] < thresholds.fetch(:min_entropy)
    issues << issue('excessive_zero_crossing', 'zero_crossing_rate', metrics[:zero_crossing_rate], {maximum: thresholds.fetch(:max_zero_crossing)}) if
      metrics[:zero_crossing_rate] > thresholds.fetch(:max_zero_crossing)
    issues << issue('low_bit_depth', 'bit_depth', metrics[:bit_depth], {minimum: thresholds.fetch(:min_bit_depth)}) if
      metrics[:bit_depth] < thresholds.fetch(:min_bit_depth)
    issues << issue('integrated_loudness_out_of_range', 'integrated_lufs', metrics[:integrated_lufs], range_threshold(thresholds.fetch(:integrated_lufs))) unless
      thresholds.fetch(:integrated_lufs).cover?(metrics[:integrated_lufs])
    issues << issue('excessive_loudness_range', 'loudness_range_lu', metrics[:loudness_range_lu], {maximum: thresholds.fetch(:max_loudness_range)}) if
      metrics[:loudness_range_lu] > thresholds.fetch(:max_loudness_range)
    issues << issue('true_peak_too_high', 'true_peak_db', metrics[:true_peak_db], {maximum: thresholds.fetch(:max_true_peak_db)}) if
      metrics[:true_peak_db] > thresholds.fetch(:max_true_peak_db)
    issues << issue('excessive_silence', 'silence_ratio', metrics[:silence_ratio], {maximum: thresholds.fetch(:max_silence_ratio)}) if
      metrics[:silence_ratio] > thresholds.fetch(:max_silence_ratio)
    issues << issue('background_noise', 'estimated_noise_floor_db', metrics[:estimated_noise_floor_db], {maximum: thresholds.fetch(:max_estimated_noise_floor_db)}) if
      metrics[:estimated_noise_floor_db] > thresholds.fetch(:max_estimated_noise_floor_db)
    issues << issue('low_estimated_snr', 'estimated_snr_db', metrics[:estimated_snr_db], {minimum: thresholds.fetch(:min_estimated_snr_db)}) if
      metrics[:estimated_snr_db] < thresholds.fetch(:min_estimated_snr_db)
    issues << issue('active_leading_edge', 'leading_rms_db', metrics[:leading_rms_db], {maximum: thresholds.fetch(:max_edge_rms_db)}, severity: 'warning') if
      metrics[:leading_rms_db] > thresholds.fetch(:max_edge_rms_db)
    issues << issue('active_trailing_edge', 'trailing_rms_db', metrics[:trailing_rms_db], {maximum: thresholds.fetch(:max_edge_rms_db)}, severity: 'warning') if
      metrics[:trailing_rms_db] > thresholds.fetch(:max_edge_rms_db)
    issues
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

  def frame_signal(path)
    command = [
      'ffmpeg', '-hide_banner', '-nostats', '-i', path,
      '-af', 'astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-',
      '-f', 'null', '-'
    ]
    stdout, stderr, status = Sh.run(command)
    Sh.assert_success!('audio frame signal analysis failed', stderr, status: status)
    levels   = frame_levels("#{stdout}\n#{stderr}")
    interior = levels.size > 2 ? levels[1...-1] : levels
    quiet    = percentile(interior, 0.1)
    speech   = percentile(interior, 0.9)
    {
      estimated_noise_floor_db: quiet,
      estimated_snr_db:         (speech - quiet).round(6),
      leading_rms_db:           levels.first,
      trailing_rms_db:          levels.last
    }
  end

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

  def reported_thresholds
    {
      silence_threshold_db:         thresholds.fetch(:silence_threshold_db),
      max_silence_ratio:            thresholds.fetch(:max_silence_ratio),
      max_loudness_range:           thresholds.fetch(:max_loudness_range),
      min_integrated_lufs:          thresholds.fetch(:integrated_lufs).min,
      max_integrated_lufs:          thresholds.fetch(:integrated_lufs).max,
      max_true_peak_db:             thresholds.fetch(:max_true_peak_db),
      max_peak_db:                  thresholds.fetch(:max_peak_db),
      min_rms_db:                   thresholds.fetch(:rms_db).min,
      max_rms_db:                   thresholds.fetch(:rms_db).max,
      min_entropy:                  thresholds.fetch(:min_entropy),
      max_zero_crossing:            thresholds.fetch(:max_zero_crossing),
      min_bit_depth:                thresholds.fetch(:min_bit_depth),
      max_estimated_noise_floor_db: thresholds.fetch(:max_estimated_noise_floor_db),
      min_estimated_snr_db:         thresholds.fetch(:min_estimated_snr_db),
      max_edge_rms_db:              thresholds.fetch(:max_edge_rms_db)
    }
  end

  def frame_levels(output)
    levels = output.scan(/lavfi\.astats\.Overall\.RMS_level=(-?(?:\d+(?:\.\d+)?|inf))/).flatten.map do |value|
      value == '-inf' ? ANALYSIS_FLOOR_DB : value.to_f
    end
    raise 'audio frame signal analysis returned no RMS levels' if levels.empty?

    levels
  end

  def percentile(values, ratio)
    sorted = values.sort
    sorted[[(sorted.size * ratio).ceil - 1, 0].max]
  end

  def issue(code, metric_name, observed, threshold, severity: 'error')
    {
      code:      code,
      severity:  severity,
      metric:    metric_name,
      observed:  observed,
      threshold: threshold
    }
  end

  def range_threshold(range)
    {minimum: range.min, maximum: range.max}
  end

  def metric(output, name)
    output.scan(/#{Regexp.escape(name)}:\s+(-?\d+(?:\.\d+)?)/).flatten.last.to_f
  end
end
