require_relative '../subtitler/ass'
require_relative '../subtitler'
require_relative '../translator'
require_relative '../output'
require_relative '../utils/sh'

class Zipper
  # All subtitle-related responsibilities live here.
  module Subtitle
    extend self

    def safe_ass_prefix(prefix)
      s = prefix.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').gsub(/[^0-9A-Za-z]+/, '_').gsub(/\A_+|_+\z/, '')
      s = s[0, 120]
      s.empty? ? 'sub' : s
    end

    def apply(zipper)
      return unless subtitles_requested?(zipper.opts)

      vtt, lng, tsp = source_vtt(zipper, translate_to: zipper.opts.lang)
      vtt = Subtitler::VTT.clean(vtt)
      zipper.stl&.update 'transcoding'

      stream = zipper.probe.streams.find { |s| s.codec_type == 'video' }
      portrait = stream.width < stream.height
      ass_mode = zipper.opts.nowords ? :plain : :instagram
      ass_body = Subtitler::Ass.from_vtt(vtt, portrait:, mode: ass_mode)

      dir = File.dirname(zipper.outfile || zipper.infile)
      prefix = zipper.outfile ? File.basename(zipper.outfile, File.extname(zipper.outfile)) : 'sub'
      ass_path = File.join(dir, "#{safe_ass_prefix(prefix)}.ass")
      File.write ass_path, ass_body
      zipper.fgraph << "ass=#{Sh.escape(ass_path)}"

      vtt_path = File.join(dir, "#{prefix}.vtt")
      File.write vtt_path, vtt
      zipper.iopts << " -i #{Sh.escape(vtt_path)}"
      if zipper.opts.speed == 1
        meta = " -c:s mov_text -metadata:s:s:0 language=#{lng} -metadata:s:s:0 title=#{lng}"
        zipper.oopts << meta
      end
    end

    # Prepare subtitles (download, transcribe, translate) and return
    # [vtt_string, language_iso, whisper_json_or_nil]
    def prepare(zipper, translate_to: nil)
      vtt = lng = tsp = nil
      vtt, lng = fetch(zipper) unless zipper.opts.gensubs

      if vtt.nil?
        zipper.stl&.update 'transcribing'
        res = Subtitler.transcribe(zipper.infile)
        tsp = res.output
        lng = res.lang
        vtt = Subtitler::VTT.build(tsp, word_tags: !zipper.opts.nowords)
        zipper.info.language ||= lng if zipper.info.respond_to?(:language)
      end

      vtt, lng, tsp = Subtitler::VTT.translate_if_needed(zipper, vtt, tsp, lng, translate_to)
      [Subtitler::VTT.clean(vtt), lng, tsp]
    end

    def prepare_subtitle(infile, info:, probe:, stl:, opts:)
      zipper = Zipper.new(infile, nil, info: info, probe: probe, stl: stl, opts: opts)
      prepare(zipper, translate_to: opts&.lang)
    end

    def generate_srt(infile, dir:, info:, probe:, stl:, opts:)
      opts ||= SymMash.new
      opts.format ||= Zipper::Types.audio.opus unless opts.respond_to?(:format) && opts.format
      opts.audio  ||= 1

      vtt, lng, tsp = prepare_subtitle(infile, info: info, probe: probe, stl: stl, opts: opts)

      srt_path = Output.filename(info, dir: dir, ext: 'srt')
      srt_content = if tsp
        Subtitler.srt_convert(tsp, word_tags: (!opts.nowords && !opts.onlysrt))
      else
        vtt_for_conversion = opts.onlysrt ? Subtitler.strip_word_tags(vtt) : vtt
        tmp_vtt = File.join(dir, 'sub.vtt')
        File.write tmp_vtt, vtt_for_conversion
        content, _, status = Sh.run "#{Zipper::FFMPEG} -i #{Sh.escape tmp_vtt} -f srt -"
        raise 'srt conversion failed' unless status.success?
        content
      end

      if (target_lang = Subtitler.normalize_lang(opts.lang)) && lng.to_s != target_lang.to_s
        from_lang = lng if lng.present?
        srt_content = Translator.translate_srt srt_content, from: from_lang, to: target_lang
        lng = target_lang
      end

      srt_content = Subtitler::SRT.filter_noise(srt_content)
      File.binwrite srt_path, "\uFEFF" + srt_content.encode('UTF-8')
      srt_path
    end

    def subtitles_requested?(opts)
      opts.lang || opts.subs || opts.onlysrt || opts.sub_vtt
    end

    def source_vtt(zipper, translate_to:)
      if (provided = zipper.opts.sub_vtt).present?
        initial = Subtitler::VTT.clean(provided.to_s)
        Subtitler::VTT.translate_if_needed(zipper, initial, nil, zipper.opts.sub_lang || zipper.opts.lang, translate_to)
      else
        prepare(zipper, translate_to: translate_to)
      end
    end

    def fetch(zipper)
      subtitles = zipper.info&.subtitles
      return fetch_scraped(zipper, subtitles) if subtitles.present?

      fetch_embedded(zipper)
    end

    def fetch_scraped(zipper, subtitles)
      lang = preferred_lang(zipper, subtitles)
      return [nil, nil] unless lang

      entry = subtitles[lang].find { |sub| sub.ext == 'vtt' } || subtitles[lang].first
      body  = Utils::HTTP.get(entry.url).body
      vtt   = Subtitler::VTT.to_vtt(body, entry.ext)
      zipper.stl&.update "subs:scraped:#{lang}"
      [vtt, lang]
    end

    def fetch_embedded(zipper)
      streams = zipper.probe.streams.select { |s| s.codec_type == 'subtitle' }
      return [nil, nil] if streams.blank?

      streams.each { |stream| stream.lang = ISO_639.find_by_code(stream.tags.language)&.alpha2 }
      index = streams.index { |stream| subtitle_match?(zipper.opts.lang, stream) }
      return [nil, nil] unless index

      vtt = Subtitler::VTT.extract_embedded(zipper, index)
      lang = streams[index].lang
      zipper.stl&.update "subs:embedded:#{lang}"
      [vtt, lang]
    end

    def preferred_lang(zipper, subtitles)
      candidates = [Subtitler.normalize_lang(zipper.opts.lang), :en, subtitles.keys.first].compact
      candidates.find { |code| subtitles.key?(code) }
    end

    def subtitle_match?(desired, stream)
      desired.present? && desired.in?([stream.lang, stream.tags.language, stream.tags.title])
    end

    private :subtitles_requested?, :source_vtt, :fetch, :fetch_scraped,
            :fetch_embedded, :preferred_lang, :subtitle_match?
    private :safe_ass_prefix
  end
end
