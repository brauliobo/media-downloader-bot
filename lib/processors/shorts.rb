require_relative '../shorts'

module Processors
  class Shorts < Base

    attr_reader :dir, :msg, :st

    # Purposefully avoid creating tmp dirs for this strategy-only processor
    def initialize dir:, msg: nil, st: nil, stline: nil, **_params
      @dir  = dir
      @tmp  = nil
      @msg  = msg || Bot::MsgHelpers.fake_msg
      @st   = st || stline&.status
      @stl  = stline
    end

    def generate_and_upload_shorts(i)
      @stl&.update 'generating shorts plan'
      srt = if i.opts.genshorts.is_a?(String) && ::File.exist?(i.opts.genshorts)
        ::File.read(i.opts.genshorts)
      else
        ::File.read Zipper.generate_srt(i.fn_in, dir: dir, info: i.info, probe: i.probe, stl: @stl, opts: i.opts)
      end
      lang = i.opts.slang || (i.info.respond_to?(:language) ? i.info.language : nil)

      cuts = begin
        ::Shorts.generate_cuts_from_srt(srt, language: lang)
      rescue => e
        @stl&.update "claude failed: #{e.message}"; []
      end

      if cuts.blank?
        total = (i.durat || i.probe.format.duration.to_i).to_i
        t = 0
        cuts = []
        while t < total
          cuts << { start: Time.at(t).utc.strftime('%H:%M:%S'), end: Time.at([t + 60, total].min).utc.strftime('%H:%M:%S'), title: "Short #{cuts.size + 1}" }
          t += 60
        end
        @stl&.update "fallback plan: #{cuts.size} cuts"
      else
        @stl&.update "cuts planned: #{cuts.size}"
      end

      vtt_src = build_vtt_source(srt)
      uploads = cuts.each_with_index.filter_map do |c, idx|
        process_cut(i, c, idx, lang, vtt_src)
      end

      @stl&.update "cutting done: #{uploads.size} files"
      regen_titles(i, srt, cuts, uploads, lang)
      i.uploads = uploads
    end

    private

    def build_vtt_source(srt)
      return nil unless srt.include?('-->')
      srt.include?('WEBVTT') ? srt : Subtitler::VTT.srt_to_vtt(srt)
    rescue => e
      STDERR.puts "[SHORTS] VTT conversion: #{e.message}"; nil
    end

    def process_cut(i, c, idx, lang, vtt_src)
      fn_out = Output.filename(i.info, dir: dir, ext: i.format&.ext || 'mp4', pos: idx + 1)
      locopts = SymMash.new(i.opts.deep_dup)
      locopts.ss = c[:start]
      locopts.to = c[:end]
      locopts.subs = nil
      locopts.onlysrt = nil
      locopts.genshorts = nil
      locopts.caption = 1

      if vtt_src
        slice_vtt = Subtitler::VTT.slice(vtt_src, from: c[:start], to: c[:end])
        locopts.sub_vtt = slice_vtt
        locopts.sub_lang = lang if lang
        (i.opts._vtt_slices ||= [])[idx] = slice_vtt
      end

      s_dur = Utils::Duration.new(c[:end]) - Utils::Duration.new(c[:start])
      s_dur = 60 if s_dur <= 0
      locopts.delete(:format)
      chosen = Zipper.choose_format(Zipper::Types.video, locopts, s_dur)
      locopts.format = chosen || Zipper::Types.video.h264

      o, e, st = Zipper.zip_video(::File.expand_path(i.fn_in), ::File.expand_path(fn_out), opts: locopts, probe: i.probe, stl: @stl, info: i.info)
      if st != 0
        @stl&.error("convert failed: #{o}\n#{e}")
        return nil
      end

      SymMash.new(path: fn_out, fn_out: fn_out, caption: c[:title].to_s.strip.presence || i.info.title,
                  info: i.info, type: SymMash.new(name: :video), opts: locopts, mime: 'video/mp4')
    end

    def regen_titles(i, srt, cuts, uploads, lang)
      return unless i.opts._vtt_slices&.any?
      titles = ::Shorts.generate_titles_for_segments(srt, cuts, language: lang, vtt_slices: i.opts._vtt_slices)
      uploads.each_with_index { |up, j| up.caption = titles[j].presence || up.caption }
    rescue => e
      @stl&.update "title regen failed: #{e.message}"
    end

  end
end
