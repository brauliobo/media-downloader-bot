module Processors
  class Shorts < Base

    # Purposefully avoid creating tmp dirs for this strategy-only processor
    def initialize dir:, bot:, msg: nil, st: nil, stline: nil, **_params
      @dir  = dir
      @tmp  = nil
      @bot  = bot
      @msg  = msg || bot.fake_msg
      @st   = st || stline.status
      @stl  = stline
    end

    def generate_and_upload_shorts(i)
      @stl&.update 'generating shorts plan'
      srt = nil
      if i.opts.genshorts.is_a?(String) && ::File.exist?(i.opts.genshorts)
        srt = ::File.read(i.opts.genshorts)
      else
        srt_path = Zipper.generate_srt(i.fn_in, dir: dir, info: i.info, probe: i.probe, stl: @stl, opts: i.opts)
        srt = ::File.read srt_path
      end
      sub_lang = i.info.respond_to?(:language) ? i.info.language : nil
      lang = i.opts.lang || sub_lang
      cuts = begin
        Shorts.generate_cuts_from_srt(srt, language: lang)
      rescue => e
        @stl&.update "ollama failed: #{e.message}"; []
      end

      if cuts.blank?
        total = (i.durat || i.probe.format.duration.to_i).to_i
        step  = 60
        t = 0
        cuts = []
        while t < total
          s = t; e = [t + step, total].min
          cuts << { start: Time.at(s).utc.strftime('%H:%M:%S'), end: Time.at(e).utc.strftime('%H:%M:%S') }
          t += step
        end
        begin
          titles = Shorts.generate_titles_for_segments(srt, cuts, language: lang)
          cuts.each_with_index { |c, idx| c[:title] = titles[idx].presence || "Short #{idx+1}" }
        rescue => e
          begin
            vtt_src = srt.include?('WEBVTT') ? srt : Subtitler::VTT.srt_to_vtt(srt)
          rescue; vtt_src = nil; end
          cuts.each_with_index do |c, idx|
            guess = vtt_src ? Shorts.title_from_vtt(Subtitler::VTT.slice(vtt_src, from: c[:start], to: c[:end])) : nil
            c[:title] = (guess.presence || "Short #{idx+1}")
          end
          @stl&.update "fallback titles used (#{e.message})"
        end
        @stl&.update "fallback plan generated: #{cuts.size} cuts"
      else
        @stl&.update "cuts planned: #{cuts.size}"
      end

      uploads = []
      cuts.each_with_index do |c, idx|
        fn_out = Output.filename(i.info, dir: dir, ext: i.format&.ext || 'mp4', pos: idx+1)
        locopts = SymMash.new(i.opts.deep_dup)
        locopts[:ss] = c[:start]
        locopts[:to] = c[:end]
        locopts[:subs] = nil
        locopts[:onlysrt] = nil
        locopts[:genshorts] = nil
        locopts[:caption] = 1
        begin
            if srt && srt.include?('-->')
            vtt_src = srt.include?('WEBVTT') ? srt : Subtitler::VTT.srt_to_vtt(srt)
          end
        rescue; vtt_src = nil; end
        if vtt_src
          slice_vtt = Subtitler::VTT.slice(vtt_src, from: c[:start], to: c[:end])
          locopts[:sub_vtt] = slice_vtt
          locopts[:sub_lang] = lang if lang
          locopts[:_sub_prefix] = "sub_#{idx+1}"
          (i.opts._vtt_slices ||= [])[idx] = slice_vtt
        end
        s_dur = (hms_to_seconds(c[:end]) || 0) - (hms_to_seconds(c[:start]) || 0)
        s_dur = 60 if s_dur <= 0
        chosen = Zipper.choose_format(Zipper::Types.video, locopts, s_dur)
        locopts.format = chosen || Zipper::Types.video.h264

        fn_out_abs = File.expand_path(fn_out)
        fn_in_abs = File.expand_path(i.fn_in)
        o, e, st = Zipper.zip_video(fn_in_abs, fn_out_abs, opts: locopts, probe: i.probe, stl: @stl, info: i.info)
        next @stl&.error("convert failed: #{o}\n#{e}") if st != 0

        uploads << SymMash.new(path: fn_out, caption: c[:title].to_s.strip.presence || i.info.title)
      end

      @stl&.update "cutting done: #{uploads.size} files"
      begin
        if i.opts._vtt_slices&.any?
          titles = Shorts.generate_titles_for_segments(srt, cuts, language: lang, vtt_slices: i.opts._vtt_slices)
          uploads.each_with_index { |up, j| up.caption = titles[j].presence || up.caption }
        end
      rescue => e
        @stl&.update "title regen failed: #{e.message}"
      end
      i.uploads = uploads
    end

  end
end
