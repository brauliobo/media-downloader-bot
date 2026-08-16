require_relative '../shorts'
require_relative '../utils/safety'

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
      source = if i.opts.genshorts.is_a?(String) && local_genshorts_path?(i.opts.genshorts)
        ::File.read(i.opts.genshorts)
      else
        ::File.read Zipper.generate_srt(i.fn_in, dir: dir, info: i.info, probe: i.probe, stl: @stl, opts: i.opts)
      end
      subtitle = parse_subtitle(source)
      lang = i.opts.slang || (i.info.respond_to?(:language) ? i.info.language : nil)

      cuts = begin
        ::Shorts.generate_cuts(subtitle, language: lang)
      rescue => e
        @stl&.update "codex failed: #{e.message}"; []
      end

      if cuts.blank?
        total = (i.durat || i.probe.format.duration.to_i).to_i
        t = 0
        cuts = []
        while t < total
          cuts << ::Shorts::Cut.new(
            start:  Time.at(t).utc.strftime('%H:%M:%S'),
            finish: Time.at([t + 60, total].min).utc.strftime('%H:%M:%S'),
            title:  "Short #{cuts.size + 1}"
          )
          t += 60
        end
        @stl&.update "fallback plan: #{cuts.size} cuts"
      else
        @stl&.update "cuts planned: #{cuts.size}"
      end

      slices  = []
      uploads = cuts.each_with_index.filter_map do |cut, idx|
        slice  = subtitle.slice(from: cut.start, to: cut.finish)
        upload = process_cut(i, cut, idx, lang, slice)
        slices << slice if upload
        upload
      end

      @stl&.update "cutting done: #{uploads.size} files"
      regen_titles(uploads, slices, lang)
      i.uploads = uploads
    end

    private

    def local_genshorts_path?(path)
      Utils::Safety.real_file_inside?(path, dir)
    end

    def parse_subtitle(source)
      source.lstrip.start_with?('WEBVTT') ? Subtitler::Subtitle.from_vtt(source) : Subtitler::Subtitle.from_srt(source)
    end

    def process_cut(i, cut, idx, lang, subtitle)
      fn_out = Output.filename(i.info, dir: dir, ext: i.format&.ext || 'mp4', pos: idx + 1)
      locopts = SymMash.new(i.opts.deep_dup)
      locopts.ss = cut.start
      locopts.to = cut.finish
      locopts.subs = nil
      locopts.onlysrt = nil
      locopts.genshorts = nil
      locopts.caption = 1

      locopts.sub_vtt = subtitle.to_vtt
      locopts.sub_lang = lang if lang

      s_dur = Utils::Duration.new(cut.finish) - Utils::Duration.new(cut.start)
      s_dur = 60 if s_dur <= 0
      locopts.delete(:format)
      chosen = Zipper.choose_format(Zipper::Types.video, locopts, s_dur)
      locopts.format = chosen || Zipper::Types.video.h264

      _output, error, status = Zipper.zip_video(
        ::File.expand_path(i.fn_in), ::File.expand_path(fn_out),
        opts: locopts, probe: i.probe, stl: @stl, info: i.info
      )
      return STDERR.puts "[SHORTS] cut #{idx + 1} convert failed: #{error}" unless status.success?

      SymMash.new(path: fn_out, fn_out: fn_out, caption: cut.title.strip.presence || i.info.title,
                  info: i.info, type: SymMash.new(name: :video), opts: locopts, mime: 'video/mp4')
    end

    def regen_titles(uploads, subtitles, lang)
      return if subtitles.empty?
      titles = ::Shorts.generate_titles(subtitles, language: lang)
      uploads.each_with_index { |up, j| up.caption = titles[j].presence || up.caption }
    rescue => e
      @stl&.update "title regen failed: #{e.message}"
    end

  end
end
