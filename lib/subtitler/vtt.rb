require 'tempfile'

require_relative '../ffmpeg'
require_relative '../utils/safety'
require_relative 'subtitle'

class Subtitler
  class VTT
    def self.clean(vtt)
      return vtt unless vtt

      vtt
        .gsub(/\{\\[^}]*\}/, '')
        .gsub(/\\h/i, ' ')
        .gsub(/\\t/i, ' ')
        .gsub(/\\[Nn]/, "\n")
    end

    def self.translate(vtt, to:, from: nil, word_tags: true)
      subtitle = Subtitle.from_vtt(clean(vtt))
      return vtt if subtitle.entries.empty?

      translated = subtitle.translated(
        from:           from,
        to:             to,
        merge_adjacent: false
      )
      translated.to_vtt(word_tags: word_tags)
    end

    def self.slice(vtt, from:, to:, rebase: true)
      Subtitle.from_vtt(vtt).slice(from: from, to: to, rebase: rebase).to_vtt
    end

    def self.srt_to_vtt(srt)
      Subtitle.from_srt(srt).to_vtt
    end

    def self.to_vtt(body, ext, ffmpeg: FFmpeg.new)
      safe_ext = Utils::Safety.subtitle_ext(ext)
      if safe_ext == 'vtt'
        utf8 = body.dup.force_encoding(Encoding::UTF_8)
        raise Encoding::InvalidByteSequenceError, 'invalid byte sequence in UTF-8' unless utf8.valid_encoding?

        canonical = canonicalize_timestamps(clean(utf8.gsub(/\r\n?|\r/, "\n")))
        validate_native_vtt!(canonical)
        return canonical
      end

      Tempfile.create(['sub', ".#{safe_ext}"]) do |file|
        file.binmode
        file.write(body)
        file.flush
        vtt = ffmpeg.convert_subtitle(
          input: file.path, format: :vtt, label: 'VTT conversion failed'
        )
        clean(vtt)
      end
    end

    def self.extract_embedded(zipper, index, ffmpeg: FFmpeg.new)
      vtt = ffmpeg.convert_subtitle(
        input: zipper.infile, format: :vtt, stream_index: index,
        label: 'VTT extraction failed'
      )
      clean(vtt)
    end

    def self.validate_native_vtt!(vtt)
      Subtitle.from_vtt(vtt)
    rescue ArgumentError
      raise ArgumentError, 'invalid WEBVTT cue range'
    end

    def self.canonicalize_timestamps(vtt)
      vtt.each_line.map do |line|
        if line.strip.match?(Subtitler::CUE_TIMING)
          count = 0
          line.gsub(Subtitler::TIMESTAMP_VALUE) do |timestamp|
            count += 1
            count <= 2 ? timestamp.tr(',', '.') : timestamp
          end
        else
          line.gsub(Subtitler::INLINE_TIMESTAMP) { |timestamp| timestamp.tr(',', '.') }
        end
      end.join
    end

    private_class_method :validate_native_vtt!, :canonicalize_timestamps
  end
end
