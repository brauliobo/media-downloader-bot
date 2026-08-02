require 'fileutils'

require_relative '../utils/sh'
require_relative '../voice_reference/audio_analyzer'
require_relative '../zipper'

module Dubbing
  module VoiceReference
    MIN_DURATION = 3.0
    MAX_DURATION = 10.0
    Reference = Data.define(:path, :text)
    Selection = Data.define(:start, :duration, :text)

    module_function

    def extract_by_speaker(input_path, segments, sentences:, dir:, min_duration: MIN_DURATION, max_duration: MAX_DURATION)
      words = Array(sentences).flat_map { |sentence| Array(sentence.source_words) }
      Array(segments).group_by(&:speaker_id).each_with_index.to_h do |(speaker_id, speaker_segments), index|
        speaker_dir = File.join(dir, format('speaker-%04d', index))
        FileUtils.mkdir_p(speaker_dir)
        selections = select(speaker_segments, sentences, words, min_duration, max_duration)
        raise "speaker #{speaker_id} has no usable reference" if selections.empty?

        clips = selections.map.with_index do |selection, idx|
          extract_span(input_path, selection, speaker_dir, idx + 1)
        end
        path = File.join(speaker_dir, 'speaker.wav')
        Zipper.concat_audio(clips, path)
        text = selections.map(&:text).reject(&:empty?).join(' ')
        raise "speaker #{speaker_id} has no reference transcript" if text.empty?

        [speaker_id, Reference.new(path: path, text: text)]
      end
    end

    def select(segments, sentences, words, min_duration, max_duration)
      available = Array(segments).filter_map do |segment|
        start = segment.start.to_f
        duration = [segment.end.to_f - start, max_duration].min
        next unless duration.positive?

        Selection.new(
          start:    start,
          duration: duration,
          text:     reference_text(start, start + duration, sentences, words)
        )
      end
      return [] if available.empty?

      selected = bounded(available, max_duration)
      while selected.sum(&:duration) < min_duration
        remaining = max_duration - selected.sum(&:duration)
        candidate = available.find { |selection| selection.duration <= remaining }
        break unless candidate

        selected << candidate
      end
      selected
    end

    def reference_text(start, finish, sentences, words)
      matched_words = Array(words).select { |word| overlap(start, finish, word.start, word.end).positive? }
      return matched_words.map { |word| word.word.to_s.strip }.reject(&:empty?).join(' ') if matched_words.any?

      Array(sentences).select do |sentence|
        overlap(start, finish, sentence.start, sentence.end).positive?
      end.map(&:source_text).map(&:to_s).map(&:strip).reject(&:empty?).join(' ')
    end

    def overlap(left_start, left_end, right_start, right_end)
      [[left_end.to_f, right_end.to_f].min - [left_start.to_f, right_start.to_f].max, 0.0].max
    end

    def bounded(selections, capacity, stop_at: capacity)
      total = 0.0
      selections.each_with_object([]) do |selection, result|
        break result if total >= stop_at || total >= capacity
        next if total + selection.duration > capacity

        result << selection
        total += selection.duration
      end
    end

    def extract_span(input_path, span, dir, idx)
      out = File.join(dir, format('speaker-%04d.wav', idx))
      cmd = "#{Zipper::FFMPEG} -ss #{span.start} -t #{span.duration} -i #{Sh.escape(input_path)} " \
            "-vn -af #{Sh.escape(::VoiceReference::AudioAnalyzer::REFERENCE_FILTER)} " \
            "-ac 1 -ar 22050 #{Sh.escape(out)}"
      _, stderr, status = Sh.run cmd
      raise "speaker reference extraction failed: #{stderr}" unless status.success? && File.exist?(out)

      out
    end
  end
end
