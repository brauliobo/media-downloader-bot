class TTS
  # A backend can answer 200 with silence for a text it failed to speak. A sentence with text and no sound is an error to
  # retry, not a gap left in the dub or the audiobook.
  module Audible
    PEAK_DB = -50.0

    module_function

    def check!(items, ffmpeg: FFmpeg.new)
      items.select { |item| item.fetch(:text).to_s.match?(/[\p{L}\p{N}]/) }.each do |item|
        raise "TTS returned silence for #{item[:text].to_s.truncate(80).inspect}" if silent?(item.fetch(:out_path), ffmpeg)
      end
    end

    # astats prints no number for digital silence ("-inf").
    def silent?(path, ffmpeg)
      _, stderr = ffmpeg.analyze_audio(path, kind: :signal)
      stderr.scan(/Peak level dB:\s+(-?\d+(?:\.\d+)?)/).flatten.last.then { |peak| peak.nil? || peak.to_f < PEAK_DB }
    end
  end
end
