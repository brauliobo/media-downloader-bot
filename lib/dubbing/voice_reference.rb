require 'fileutils'

require_relative '../voice_reference/audio_analyzer'
require_relative '../zipper'

module Dubbing
  module VoiceReference
    MIN_DURATION = 4.0
    MAX_DURATION = 8.0
    REFERENCE_GAP = 0.15
    Reference = Data.define(:path, :text) do
      def tts_options
        {speaker_wav: path, ref_text: text}
      end
    end
    Selection = Data.define(:start, :duration, :text)

    module_function

    def extract_by_speaker(input_path, segments, sentences:, dir:, min_duration: MIN_DURATION, max_duration: MAX_DURATION, filter: :raw, pad_duration: nil)
      Array(sentences).group_by(&:speaker_id).each_with_index.to_h do |(speaker_id, speaker_sentences), index|
        speaker_dir = File.join(dir, format('speaker-%04d', index))
        FileUtils.mkdir_p(speaker_dir)
        selections = select(speaker_sentences, min_duration, max_duration)
        raise "speaker #{speaker_id} has no usable reference" if selections.empty?

        clips = selections.map.with_index do |selection, idx|
          extract_span(input_path, selection, speaker_dir, idx + 1, filter: filter, pad_duration: pad_duration)
        end
        path = File.join(speaker_dir, 'speaker.wav')
        Zipper.concat_audio(clips, path)
        text = selections.map(&:text).reject(&:empty?).join(' ')
        raise "speaker #{speaker_id} has no reference transcript" if text.empty?

        [speaker_id, Reference.new(path: path, text: text)]
      end
    end

    def select(sentences, min_duration, max_duration)
      available = Array(sentences).filter_map do |sentence|
        text = sentence.source_text.to_s.strip
        start = sentence.start.to_f
        finish = sentence.end.to_f
        next if text.empty? || finish <= start || finish - start > max_duration

        Selection.new(start: start, duration: finish - start, text: text)
      end
      return [] if available.empty?

      selected = bounded(available, max_duration)
      while selected.sum(&:duration) < min_duration
        remaining = max_duration - selected.sum(&:duration)
        candidate = available.find do |selection|
          !selected.include?(selection) && selection.duration <= remaining
        end
        break unless candidate

        selected << candidate
      end
      selected
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

    def extract_span(input_path, span, dir, idx, filter: :raw, pad_duration: nil)
      out = File.join(dir, format('speaker-%04d.wav', idx))
      ::VoiceReference::AudioAnalyzer.new.extract_span(
        audio:        input_path,
        start:        span.start,
        duration:     span.duration,
        output:       out,
        sample_rate:  22_050,
        filter:       filter,
        pad_duration: pad_duration,
      )

      out
    end
  end
end
