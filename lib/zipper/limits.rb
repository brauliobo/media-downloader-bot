# frozen_string_literal: true

require_relative 'formats'

class Zipper
  module Limits
    VID_WIDTH_REDUC        = SymMash.new width: 80, minutes: 8
    AUD_BRATE_REDUC        = SymMash.new brate: 8, minutes: 8
    MAX_VIDEO_MAXRATE_KBIT = 50_000
    VideoSize = Data.define :maxrate, :bufsize, :rate_control, :bitrate

    module_function

    def max_audio_duration br, size_mb_limit
      1000 * size_mb_limit / (br.to_i / 8) / 60.0
    end

    def vid_duration_thld size_mb_limit
      return Float::INFINITY unless size_mb_limit

      (size_mb_limit * 20.0 / 50).ceil
    end

    def aud_duration_thld size_mb_limit
      return Float::INFINITY unless size_mb_limit

      max_audio_duration Zipper::Formats::TYPES.audio.opus.opts.bitrate, size_mb_limit
    end

    def apply_audio_size_limit! zipper
      return if zipper.opts.onlysrt
      return unless Zipper.size_mb_limit

      if max_audio_duration(zipper.opts.bitrate, Zipper.size_mb_limit) < zipper.duration / 60.0
        zipper.opts.bitrate = (zipper.opts.percent * 8 * Zipper.size_mb_limit * 1000) / zipper.duration.to_f
      end
    end

    def apply_video_size_limits! zipper
      return if zipper.opts.onlysrt
      return unless Zipper.size_mb_limit
      return unless zipper.duration.finite? && zipper.duration.positive?

      minutes = (zipper.duration / 60).ceil
      threshold = vid_duration_thld Zipper.size_mb_limit

      if minutes > threshold && zipper.opts.width > zipper.dopts.width / 3
        reduction, interval = VID_WIDTH_REDUC.values_at :width, :minutes
        zipper.opts.width -= reduction * ((minutes - threshold).to_f / interval).ceil
        zipper.opts.width = zipper.dopts.width / 3 if zipper.opts.width < zipper.dopts.width / 3
        zipper.opts.width -= 1 if zipper.opts.width.odd?
      end

      if minutes > threshold && zipper.opts.abrate > zipper.dopts.abrate / 2
        reduction, interval = AUD_BRATE_REDUC.values_at :brate, :minutes
        zipper.opts.abrate -= reduction * ((minutes - threshold).to_f / interval).ceil
        zipper.opts.abrate = zipper.dopts.abrate / 2 if zipper.opts.abrate < zipper.dopts.abrate / 2
      end

      audio_size = (zipper.duration * zipper.opts.abrate.to_f / 8) / 1000
      video_size = (Zipper.size_mb_limit - audio_size).to_i
      maxrate = (8 * (zipper.opts.percent * video_size * 1000) / zipper.duration).to_i
      maxrate = zipper.opts.vbrate if zipper.opts.vbrate && maxrate > zipper.opts.vbrate
      maxrate = MAX_VIDEO_MAXRATE_KBIT if maxrate > MAX_VIDEO_MAXRATE_KBIT

      video_size_opts zipper, maxrate: "#{maxrate}k", bufsize: "#{video_size}M"
    end

    def video_size_opts zipper, maxrate:, bufsize:
      case zipper.format_name
      when :h264, :h265
        VideoSize.new(
          maxrate:     maxrate,
          bufsize:     bufsize,
          rate_control: zipper.opts.cudaenc ? :vbr : nil,
          bitrate:     nil
        )
      when :vp9
        VideoSize.new maxrate: nil, bufsize: nil, rate_control: :vbr, bitrate: maxrate.to_i
      end
    end
  end
end
