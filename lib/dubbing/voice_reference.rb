require_relative '../utils/sh'
require_relative '../zipper'

module Dubbing
  module VoiceReference
    MAX_DURATION = 20.0

    module_function

    def extract(input_path, sentences, dir:, max_duration: MAX_DURATION)
      clips = selected_spans(sentences, max_duration).map.with_index do |span, idx|
        extract_span(input_path, span, dir, idx + 1)
      end
      return nil if clips.empty?

      out = File.join(dir, 'speaker.wav')
      Zipper.concat_audio(clips, out)
      out
    end

    def selected_spans(sentences, max_duration)
      total = 0.0
      spans = []
      Array(sentences).each do |sentence|
        start = sentence.start.to_f
        dur = sentence.end.to_f - start
        next if dur <= 0
        break if total >= max_duration

        dur = [dur, max_duration - total].min
        total += dur
        spans << SymMash.new(start: start, duration: dur)
      end
      spans
    end

    def extract_span(input_path, span, dir, idx)
      out = File.join(dir, format('speaker-%04d.wav', idx))
      cmd = "#{Zipper::FFMPEG} -ss #{span.start} -t #{span.duration} -i #{Sh.escape(input_path)} " \
            "-vn -ac 1 -ar 22050 #{Sh.escape(out)}"
      _, stderr, status = Sh.run cmd
      raise "speaker reference extraction failed: #{stderr}" unless status.success? && File.exist?(out)

      out
    end
  end
end
