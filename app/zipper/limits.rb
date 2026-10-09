# frozen_string_literal: true


class Zipper
  module Limits
    VID_WIDTH_REDUC        = SymMash.new width: 80, minutes: 8
    AUD_BRATE_REDUC        = SymMash.new brate: 8, minutes: 8
    MAX_VIDEO_MAXRATE_KBIT = 50_000
    # Encoding lowers the bitrates (and the video width) with the duration, down to these floors:
    # a reasonable 240p picture and intelligible speech. Past them nothing can fit the limit.
    MIN_AUDIO_BITRATE_KBIT = 16
    MIN_VIDEO_BITRATE_KBIT = 120
    VideoSize = Data.define :maxrate, :bufsize, :rate_control, :bitrate

    module_function

    def max_audio_duration br, size_mb_limit
      1000 * size_mb_limit / (br.to_i / 8) / 60.0
    end

    # What a size limit allows: kbit/s times seconds, so a duration gives the bitrate and a bitrate the duration.
    def kbit_seconds percent, size_mb
      8 * (percent * size_mb * 1000)
    end

    # Smallest width and audio bitrate a long video is shrunk to.
    def min_video_width(width) = width / 3
    def min_video_abrate(abrate) = abrate / 2

    # Longest media (in seconds) that still fits the limit when encoded at the floor bitrates.
    def max_encoded_duration kind, size_mb_limit
      types = Zipper::Formats::TYPES
      percent, kbit = if kind == :audio
        [types.audio.opus.opts.percent, MIN_AUDIO_BITRATE_KBIT]
      else
        profile = types.video.h264.opts
        [profile.percent, MIN_VIDEO_BITRATE_KBIT + min_video_abrate(profile.abrate)]
      end
      kbit_seconds(percent, size_mb_limit) / kbit
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
        dynamic = kbit_seconds(zipper.opts.percent, Zipper.size_mb_limit) / zipper.duration.to_f
        zipper.opts.bitrate = [dynamic, MIN_AUDIO_BITRATE_KBIT].max
      end
    end

    def apply_video_size_limits! zipper
      return if zipper.opts.onlysrt
      return unless Zipper.size_mb_limit
      return unless zipper.duration.finite? && zipper.duration.positive?

      minutes = (zipper.duration / 60).ceil
      threshold = vid_duration_thld Zipper.size_mb_limit

      min_width  = min_video_width zipper.dopts.width
      min_abrate = min_video_abrate zipper.dopts.abrate

      if minutes > threshold && zipper.opts.width > min_width
        reduction, interval = VID_WIDTH_REDUC.values_at :width, :minutes
        zipper.opts.width -= reduction * ((minutes - threshold).to_f / interval).ceil
        zipper.opts.width = min_width if zipper.opts.width < min_width
        zipper.opts.width -= 1 if zipper.opts.width.odd?
      end

      if minutes > threshold && zipper.opts.abrate > min_abrate
        reduction, interval = AUD_BRATE_REDUC.values_at :brate, :minutes
        zipper.opts.abrate -= reduction * ((minutes - threshold).to_f / interval).ceil
        zipper.opts.abrate = min_abrate if zipper.opts.abrate < min_abrate
      end

      audio_size = (zipper.duration * zipper.opts.abrate.to_f / 8) / 1000
      video_size = (Zipper.size_mb_limit - audio_size).to_i
      maxrate = (kbit_seconds(zipper.opts.percent, video_size) / zipper.duration).to_i
      maxrate = zipper.opts.vbrate if zipper.opts.vbrate && maxrate > zipper.opts.vbrate
      maxrate = MAX_VIDEO_MAXRATE_KBIT if maxrate > MAX_VIDEO_MAXRATE_KBIT
      maxrate = MIN_VIDEO_BITRATE_KBIT if maxrate < MIN_VIDEO_BITRATE_KBIT

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
