# frozen_string_literal: true

require_relative '../subtitler/ass'
require_relative '../translator'
require 'mechanize'

class Zipper
  # All subtitle-related responsibilities live here.
  module Subtitle
    module_function

    # Public entry -----------------------------------------------------------
    # Attach subtitles to a Zipper instance (video only).
    def apply(zipper)
      return if !zipper.opts.lang && !zipper.opts.subs && !zipper.opts.onlysrt

      vtt, lng, tsp = prepare(zipper)
      zipper.stl&.update 'transcoding'

      # generate ASS subtitle directly (scales font automatically for portrait videos)
      vstrea       = zipper.probe.streams.find { |s| s.codec_type == 'video' }
      is_portrait  = vstrea.width < vstrea.height
      ass_content  = Subtitler::Ass.from_vtt(vtt, portrait: is_portrait,
                                             mode: zipper.opts.nowords ? :plain : :instagram)

      assp = 'sub.ass'
      File.write assp, ass_content
      zipper.fgraph << "ass=#{assp}"

      # Write VTT (needed for embedding)
      subp = 'sub.vtt'
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

      if zipper.opts.lang && lng && zipper.opts.lang.to_s != lng.to_s
        zipper.stl&.update 'translating'
        if tsp
          tsp = Subtitler.translate(tsp, from: lng, to: zipper.opts.lang)
          vtt = Subtitler.vtt_convert(tsp, word_tags: !zipper.opts.nowords)
        else
          vtt = Translator.translate_vtt(vtt, from: lng, to: zipper.opts.lang)
        end
        lng = zipper.opts.lang
      end

      [vtt, lng, tsp]
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

      vtt, _lng, tsp = prepare_subtitle(infile, info: info, probe: probe, stl: stl, opts: opts)

      require_relative '../output'
      srt_path = Output.filename(info, dir: dir, ext: 'srt')
      if tsp
        srt_content = Subtitler.srt_convert(tsp, word_tags: !opts.nowords)
      else
        vtt_path = File.join(dir, 'sub.vtt')
        File.write vtt_path, vtt
        srt_content, _, status = Sh.run "ffmpeg -loglevel error -y -i #{Sh.escape vtt_path} -f srt -"
        raise 'srt conversion failed' unless status.success?
      end

      File.write srt_path, srt_content
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
        return [vtt, lng]
      end

      # 2) embedded subtitles ----------------------------------------------
      if (esubs = zipper.probe.streams.select { |s| s.codec_type == 'subtitle' }).present?
        esubs.each { |s| s.lang = ISO_639.find_by_code(s.tags.language).alpha2 }
        idx = esubs.index { |s| zipper.opts.lang.in? [s.lang, s.tags.language, s.tags.title] }
        return [nil, nil] unless idx
        vtt = extract_vtt(zipper, idx)
        lng = esubs[idx].lang
        zipper.opts.lang = lng
        return [vtt, lng]
      end

      [nil, nil]
    end

    def http
      Mechanize.new
    end

  end
end
