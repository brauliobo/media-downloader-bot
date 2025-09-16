# frozen_string_literal: true

require_relative '../exts/sym_mash'
require_relative 'formats'

class Zipper
  # Math helpers that convert byte / bitrate / duration numbers while keeping
  # all sizing logic in a single place.  Pure functions only – no IO.
  module Limits
    # Direct copies from Zipper constants so other code keeps working.
    VID_WIDTH_REDUC = SymMash.new width: 80, minutes: 8
    AUD_BRATE_REDUC = SymMash.new brate:  8, minutes: 8

    module_function

    # -- Class-level helpers -------------------------------------------------

    # Max audio duration (minutes) for a given bitrate and size limit.
    #   br – bitrate in kbit/s
    def max_audio_duration(br, size_mb_limit)
      1000 * size_mb_limit / (br.to_i / 8) / 60.0
    end

    # Threshold after which we start reducing video resolution.
    # Returns minutes.
    def vid_duration_thld(size_mb_limit)
      return Float::INFINITY unless size_mb_limit
      # Baseline: 20 minutes when the limit is 50 MB (Telegram). Scale linearly.
      (size_mb_limit * 20.0 / 50).ceil
    end

    # Same idea for audio.
    def aud_duration_thld(size_mb_limit)
      return Float::INFINITY unless size_mb_limit
      max_audio_duration(Zipper::Formats::TYPES.audio.opus.opts.bitrate, size_mb_limit)
    end

    # -- Instance-level helpers ---------------------------------------------
    # These two methods expect a typical Zipper instance with `duration` and
    # `opts` ivars. They mutate opts in-place and return any extra ffmpeg
    # size-limit flags as string (video) or nil (audio).

    def apply_audio_size_limit!(zipper)
      return if zipper.opts.onlysrt
      return unless Zipper.size_mb_limit

      if max_audio_duration(zipper.opts.bitrate, Zipper.size_mb_limit) < zipper.duration / 60.0
        zipper.opts.bitrate = (zipper.opts.percent * 8 * Zipper.size_mb_limit * 1000) / zipper.duration.to_f
      end
    end

    def apply_video_size_limits!(zipper)
      return if zipper.opts.onlysrt
      return unless Zipper.size_mb_limit
      return if zipper.opts.custom_width

      minutes  = (zipper.duration / 60).ceil
      vthld    = vid_duration_thld(Zipper.size_mb_limit)

      # ---- reduce resolution ---------------------------------------------
      if minutes > vthld && zipper.opts.width > zipper.dopts.width / 3
        reduc,intv  = VID_WIDTH_REDUC.values_at(:width, :minutes)
        zipper.opts.width -= reduc * ((minutes - vthld).to_f / intv).ceil
        zipper.opts.width  = zipper.dopts.width / 3 if zipper.opts.width < zipper.dopts.width / 3
        zipper.opts.width -= 1 if zipper.opts.width.odd?
      end

      # ---- reduce audio bitrate -----------------------------------------
      if minutes > vthld && zipper.opts.abrate > zipper.dopts.abrate / 2
        reduc,intv   = AUD_BRATE_REDUC.values_at(:brate, :minutes)
        zipper.opts.abrate -= reduc * ((minutes - vthld).to_f / intv).ceil
        zipper.opts.abrate  = zipper.dopts.abrate / 2 if zipper.opts.abrate < zipper.dopts.abrate / 2
      end

      audsize  = (zipper.duration * zipper.opts.abrate.to_f / 8) / 1000
      vidsize  = (Zipper.size_mb_limit - audsize).to_i
      bufsize  = "#{vidsize}M"

      maxrate  = (8 * (zipper.opts.percent * vidsize * 1000) / zipper.duration).to_i
      maxrate  = zipper.opts.vbrate if zipper.opts.vbrate && maxrate > zipper.opts.vbrate
      maxrate  = "#{maxrate}k"

      zipper.video_sz_template % {maxrate: maxrate, bufsize: bufsize}
    end
  end
end