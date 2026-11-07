class TTS
  # A backend can answer 200 with silence for a text it failed to speak. A sentence with text and no sound is an error to
  # retry; TTS.synthesize_batch only lets the few that stay silent through as gaps.
  module Audible
    PEAK_DB = -50.0

    class Silent < StandardError; end

    module_function

    def check!(items, ffmpeg: FFmpeg.new)
      items.select { |item| speakable?(item.fetch(:text)) }.each do |item|
        raise Silent, "TTS returned silence for #{item[:text].to_s.truncate(80).inspect}" if silent?(item.fetch(:out_path), ffmpeg)
      end
    end

    # Text with a letter or a digit: anything else (punctuation, emoji) has nothing to say.
    def speakable?(text) = text.to_s.match?(/[\p{L}\p{N}]/)

    # astats prints no number for digital silence ("-inf").
    def silent?(path, ffmpeg)
      _, stderr = ffmpeg.analyze_audio(path, kind: :signal)
      stderr.scan(/Peak level dB:\s+(-?\d+(?:\.\d+)?)/).flatten.last.then { |peak| peak.nil? || peak.to_f < PEAK_DB }
    end
  end
end
