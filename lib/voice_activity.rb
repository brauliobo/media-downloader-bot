require 'fileutils'
require_relative 'utils/tmp'

require_relative 'ffmpeg'
require_relative 'voice_activity/silero'

class VoiceActivity
  BACKEND = const_get(ENV.fetch('VOICE_ACTIVITY', 'Silero'))

  def self.detect(path)
    BACKEND.detect(path)
  end

  def self.with_speech(path, dir: nil)
    workdir = nil
    ranges = detect(path)
    return yield(nil, ranges) if ranges.empty?

    workdir = Utils::Tmp.dir('voice-activity-', dir)
    speech = File.join(workdir, 'speech.wav')
    FFmpeg.new.extract_speech_ranges(
      input: path, output: speech, ranges: ranges,
      sample_rate: 16_000, channels: 1, label: 'voice range extraction failed'
    )
    yield speech, ranges
  ensure
    FileUtils.remove_entry(workdir) if workdir && Dir.exist?(workdir)
  end

  def self.restore_timing!(subtitle, ranges)
    Subtitler::Subtitle.assert!(subtitle, 'subtitle')
    return subtitle if ranges.nil? || ranges.empty?

    intervals = ranges.intervals
    subtitle.entries.each { |entry| remap_entry!(entry, intervals) }
    subtitle
  end

  def self.remap_entry!(entry, intervals)
    (entry.words + entry.source_words).uniq(&:object_id).each do |word|
      word.replace_timing!(
        start:  source_time_from(word.start, intervals),
        finish: source_time_from(word.finish, intervals)
      )
    end
    entry.replace_timing!(start: source_time_from(entry.start, intervals), finish: source_time_from(entry.finish, intervals))
  end
  private_class_method :remap_entry!

  def self.source_time_from(time, intervals)
    time   = time.to_f
    cursor = 0.0
    intervals.each_with_index do |range, index|
      duration = range.finish - range.start
      last     = index == intervals.size - 1
      if time < cursor + duration || last
        mapped = range.start + (time - cursor)
        return [[mapped, range.start].max, range.finish].min
      end

      cursor += duration
    end
  end
  private_class_method :source_time_from
end
