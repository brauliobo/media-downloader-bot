# frozen_string_literal: true

require_relative '../subtitler/ass'
require_relative '../translator'
require 'mechanize'

class Zipper
  # All subtitle-related responsibilities live here.
  module Subtitle
    module_function
    def maybe_translate_vtt(zipper, vtt, tsp, from_lang, to_lang)
      return [vtt, from_lang, tsp] unless to_lang
      return [vtt, from_lang, tsp] if from_lang && to_lang.to_s == from_lang.to_s
      zipper&.stl&.update 'translating'
      if tsp
        tsp = Subtitler.translate(tsp, from: (from_lang if from_lang.present?), to: to_lang)
        vtt = Subtitler.vtt_convert(tsp, word_tags: !zipper.opts.nowords)
      else
        vtt = Translator.translate_vtt(vtt, from: (from_lang if from_lang.present?), to: to_lang)
      end
      [vtt, to_lang, tsp]
    end

    NOISE_DOTS_LINE = /\A\s*\d(?:\s*\.\s*\d){3,}\.??\s*\z/

    def filter_noise_srt(srt)
      srt.split(/\r?\n\r?\n+/).reject { |blk|
        blk.lines.reject { |l| l.strip.empty? || l.strip =~ /^\d+$/ || l.include?("-->") }
           .any? { |tl| tl.strip.match?(NOISE_DOTS_LINE) }
      }.join("\n\n")
    end

    # Public entry -----------------------------------------------------------
    # Attach subtitles to a Zipper instance (video only).
    def apply(zipper)
      return if !zipper.opts.lang && !zipper.opts.subs && !zipper.opts.onlysrt && !zipper.opts.sub_vtt

      if (sv = zipper.opts.sub_vtt).present?
        vtt, lng = sv.to_s, (zipper.opts.sub_lang || zipper.opts.lang)
      else
        vtt, lng, tsp = prepare(zipper)
      end
      vtt, lng, tsp = maybe_translate_vtt(zipper, vtt, tsp, lng, zipper.opts.lang)
      zipper.stl&.update 'transcoding'

      # generate ASS subtitle directly (scales font automatically for portrait videos)
      vstrea       = zipper.probe.streams.find { |s| s.codec_type == 'video' }
      is_portrait  = vstrea.width < vstrea.height
      ass_content  = Subtitler::Ass.from_vtt(vtt, portrait: is_portrait,
                                             mode: zipper.opts.nowords ? :plain : :instagram)

      prefix = zipper.opts._sub_prefix || 'sub'
      assp = "#{prefix}.ass"
      File.write assp, ass_content
      zipper.fgraph << "ass=#{assp}"

      # Write VTT (needed for embedding)
      subp = "#{prefix}.vtt"
      File.write subp, vtt
      zipper.iopts << " -i #{subp}"
      zipper.oopts << " -c:s mov_text -metadata:s:s:0 language=#{lng} -metadata:s:s:0 title=#{lng}" if zipper.opts.speed == 1
    end

    # Prepare subtitles (download, transcribe, translate)
    # Returns [vtt_string, language_iso, whisper_json_or_nil]
    def prepare(zipper)
      vtt = lng = tsp = nil
      vtt, lng = fetch(zipper) unless zipper.opts.gensubs

      if vtt.nil?
        zipper.stl&.update 'transcribing'
        res = Subtitler.transcribe(zipper.infile)
        tsp, lng = res.output, res.lang
        vtt = Subtitler.vtt_convert(tsp, word_tags: !zipper.opts.nowords)
        zipper.info.language ||= lng if zipper.info.respond_to?(:language)
      end

      vtt, lng, tsp = maybe_translate_vtt(zipper, vtt, tsp, lng, zipper.opts.lang)

      [vtt, lng, tsp]
    end

    # Slice a VTT by time and optionally rebase to 00:00:00
    # from/to are HH:MM:SS strings
    def slice_vtt(vtt, from:, to:, rebase: true)
      from_s = hms_to_seconds(from)
      to_s   = hms_to_seconds(to)
      out = +"WEBVTT\n\n"
      i = 0
      vtt.each_line.slice_when { |prev, line| line.strip.empty? && !prev.strip.empty? }.each do |blk|
        cue = blk.join
        next unless cue.include?("-->")
        lines = cue.lines
        timing = lines.find { |l| l.include?("-->") }
        next unless timing
        ts, te = timing.strip.split("-->").map(&:strip)
        ts_s = hms_ms_to_seconds(ts)
        te_s = hms_ms_to_seconds(te)
        next if te_s <= from_s || ts_s >= to_s
        n_ts = [ts_s - from_s, 0].max
        n_te = [te_s - from_s, 0].max
        n_ts = [n_ts, to_s - from_s].min
        n_te = [n_te, to_s - from_s].min
        if rebase
          nts = seconds_to_hms_ms(n_ts)
          nte = seconds_to_hms_ms(n_te)
        else
          nts = seconds_to_hms_ms(ts_s)
          nte = seconds_to_hms_ms(te_s)
        end
        text = (lines - [timing]).join.strip
        next if text.blank?
        i += 1
        out << "#{i}\n#{nts} --> #{nte}\n#{text}\n\n"
      end
      out
    end

    # Convert SRT string to simple VTT string (no styling), in-memory.
    def srt_text_to_vtt(srt)
      out = +"WEBVTT\n\n"
      buf = []
      srt.each_line do |line|
        if line.strip.empty?
          out << buf.join if buf.any?
          out << "\n"
          buf.clear
          next
        end

        if line.include?("-->")
          # 00:00:01,000 --> 00:00:02,000  =>  00:00:01.000 --> 00:00:02.000
          buf << line.tr(',', '.')
        elsif line.strip =~ /^\d+$/
          # drop numeric index lines
        else
          buf << line
        end
      end
      out << buf.join if buf.any?
      out
    end

    def hms_to_seconds(hms)
      return unless hms
      if hms =~ /(\d{1,2}):(\d{2}):(\d{2})/
        $1.to_i*3600 + $2.to_i*60 + $3.to_i
      end
    end

    def hms_ms_to_seconds(hms)
      return unless hms
      if hms =~ /(\d{1,2}):(\d{2}):(\d{2})([\.,](\d{3}))?/
        base = $1.to_i*3600 + $2.to_i*60 + $3.to_i
        ms = $5.to_i
        base + ms/1000.0
      end
    end

    def seconds_to_hms_ms(sec)
      sec = sec.to_f
      h = (sec/3600).floor
      m = ((sec%3600)/60).floor
      s = (sec%60).floor
      ms = ((sec - sec.floor) * 1000).round
      format('%02d:%02d:%02d.%03d', h, m, s, ms)
    end

    # ----------------------------------------------------------------------
    #  Class-level convenience wrappers (keep public API unchanged)
    # ----------------------------------------------------------------------

    def prepare_subtitle(infile, info:, probe:, stl:, opts:)
      zipper = Zipper.new(infile, nil, info: info, probe: probe, stl: stl, opts: opts)
      prepare(zipper)
    end

    def generate_srt(infile, dir:, info:, probe:, stl:, opts:)
      opts ||= SymMash.new
      opts.format ||= Zipper::Types.audio.opus unless opts.respond_to?(:format) && opts.format
      opts.audio  ||= 1 # audio-only download is enough for transcription

      vtt, lng, tsp = prepare_subtitle(infile, info: info, probe: probe, stl: stl, opts: opts)

      require_relative '../output'
      srt_path = Output.filename(info, dir: dir, ext: 'srt')
      if tsp
        # Avoid per-word timestamp tags in SRT for external processors (onlysrt)
        srt_content = Subtitler.srt_convert(tsp, word_tags: (!opts.nowords && !opts.onlysrt))
      else
        # If onlysrt, drop inline word tags from VTT before conversion
        clean_vtt = opts.onlysrt ? Subtitler.strip_word_tags(vtt) : vtt
        vtt_path = File.join(dir, 'sub.vtt')
        File.write vtt_path, clean_vtt
        srt_content, _, status = Sh.run "ffmpeg -loglevel error -y -i #{Sh.escape vtt_path} -f srt -"
        raise 'srt conversion failed' unless status.success?
      end

      # Ensure final SRT is in the requested language when provided
      if opts.lang && lng.to_s != opts.lang.to_s
        srt_content = Translator.translate_srt(srt_content, from: (lng if lng.present?), to: opts.lang) rescue srt_content
        lng = opts.lang
      end

      srt_content = filter_noise_srt(srt_content)
      File.binwrite srt_path, "\uFEFF" + srt_content.encode('UTF-8')
      srt_path
    end

    # ----------------------------------------------------------------------
    #  Internal helpers (mostly copied from original implementation)
    # ----------------------------------------------------------------------

    def subtitle_to_vtt(body, ext)
      File.write "sub.#{ext}", body
      vtt, = Sh.run "ffmpeg -i sub.#{ext} -c:s webvtt -f webvtt -"
      vtt
    end

    def extract_vtt(zipper, lang_or_index)
      subs  = zipper.probe.streams.select { |s| s.codec_type == 'subtitle' }
      index = lang_or_index.is_a?(Numeric) ? lang_or_index :
              subs.index { |s| s.tags.language == lang_or_index }

      vtt, = Sh.run "ffmpeg -loglevel error -i #{Sh.escape zipper.infile} -map 0:s:#{index} -c:s webvtt -f webvtt -"
      vtt
    end

    def fetch(zipper)
      # 1) scraped subtitles -------------------------------------------------
      if (subs = zipper.info&.subtitles).present?
        candidates = [zipper.opts.lang, :en, subs.keys.first]
        lng, lsub = candidates.find { |c| subs.key?(c) }, nil
        return [nil, nil] unless lng
        lsub = subs[lng].find { |s| s.ext == 'vtt' } || subs[lng][0]
        sub  = http.get(lsub.url).body
        vtt  = subtitle_to_vtt(sub, lsub.ext)
        zipper.stl&.update "subs:scraped:#{lng}"
        return [vtt, lng]
      end

      # 2) embedded subtitles ----------------------------------------------
      if (esubs = zipper.probe.streams.select { |s| s.codec_type == 'subtitle' }).present?
        esubs.each { |s| s.lang = ISO_639.find_by_code(s.tags.language).alpha2 }
        idx = esubs.index { |s| zipper.opts.lang.in? [s.lang, s.tags.language, s.tags.title] }
        return [nil, nil] unless idx
        vtt = extract_vtt(zipper, idx)
        lng = esubs[idx].lang
        zipper.stl&.update "subs:embedded:#{lng}"
        return [vtt, lng]
      end

      [nil, nil]
    end

    def http
      Mechanize.new
    end

  end
end
