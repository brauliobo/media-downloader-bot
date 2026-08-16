require_relative '../subtitler/ass'
require_relative '../subtitler'
require_relative '../output'
require_relative '../ffmpeg'

class Zipper
  # All subtitle-related responsibilities live here.
  module Subtitle
    extend self

    def safe_ass_prefix(prefix)
      s = prefix.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').gsub(/[^0-9A-Za-z]+/, '_').gsub(/\A_+|_+\z/, '')
      s = s[0, 120]
      s.empty? ? 'sub' : s
    end

    def apply zipper
      return unless subtitles_requested?(zipper.opts)

      subtitle = prepare(zipper, translate_to: subtitle_translation_target(zipper.opts))
      zipper.stl&.update 'transcoding'

      stream = zipper.probe.streams.find { |s| s.codec_type == 'video' }
      portrait = stream.width < stream.height
      ass_mode = zipper.opts.nowords ? :plain : :instagram
      ass_body = subtitle.to_ass(portrait:, mode: ass_mode, preset: zipper.opts.subpreset)

      dir = File.dirname(zipper.outfile || zipper.infile)
      prefix = zipper.outfile ? File.basename(zipper.outfile, File.extname(zipper.outfile)) : 'sub'
      ass_path = File.join(dir, "#{safe_ass_prefix(prefix)}.ass")
      File.write ass_path, ass_body
      zipper.burn_subtitle ass_path

      if zipper.opts.speed == 1
        vtt_path = File.join(dir, "#{prefix}.vtt")
        File.write vtt_path, subtitle.to_vtt(word_tags: !zipper.opts.nowords)
        zipper.add_subtitle_input vtt_path, language: subtitle.language
      end
    end

    # Prepare subtitles by downloading or transcribing, then translating when requested.
    def prepare(zipper, translate_to: nil)
      subtitle = provided_subtitle(zipper)
      subtitle ||= fetch(zipper) unless zipper.opts.gensubs

      unless subtitle
        zipper.stl&.update 'transcribing'
        subtitle = Subtitler.transcribe(zipper.infile)
        normalize_language!(subtitle)
        subtitle.normalize_entries!
        zipper.info.language ||= subtitle.language if zipper.info.respond_to?(:language)
      end

      translate_if_needed(zipper, subtitle, translate_to)
    end

    def prepare_subtitle infile, info:, probe:, stl:, opts:, ffmpeg: nil, ffmpeg_factory: nil
      zipper = Zipper.new infile, nil, info: info, probe: probe, stl: stl, opts: opts,
                          ffmpeg: ffmpeg, ffmpeg_factory: ffmpeg_factory
      prepare(zipper, translate_to: subtitle_translation_target(opts))
    end

    def generate_srt infile, dir:, info:, probe:, stl:, opts:, ffmpeg: nil
      opts ||= SymMash.new
      opts.format ||= Zipper::Types.audio.opus unless opts.respond_to?(:format) && opts.format
      opts.audio  ||= 1

      subtitle = prepare_subtitle(
        infile, info: info, probe: probe, stl: stl, opts: opts, ffmpeg: ffmpeg
      )

      srt_path = Output.filename(info, dir: dir, ext: 'srt')

      if (target_lang = Subtitler.normalize_lang(opts.slang)) && subtitle.language.to_s != target_lang.to_s
        subtitle = subtitle.translated(
          from:           subtitle.language.presence,
          to:             target_lang,
          merge_adjacent: false
        )
      end

      subtitle.reject_noise!
      srt_content = subtitle.to_srt(word_tags: !opts.nowords && !opts.onlysrt)
      File.binwrite srt_path, "\uFEFF" + srt_content.encode('UTF-8')
      srt_path
    end

    def subtitles_requested?(opts)
      return false if subtitle_mode(opts) == 'none'

      opts.slang || opts.sub_mode.present? || opts.sub.present? || opts.subs || opts.gensubs || opts.onlysrt ||
        opts.subtitle || opts.sub_vtt
    end

    def sanitize_vtt vtt
      Subtitler::VTT.clean vtt
    end

    def subtitle_mode(opts)
      return opts.sub_mode.to_s if opts.sub_mode.present?
      return 'language' if opts.sub.present?

      ''
    end

    def subtitle_translation_target(opts)
      mode = subtitle_mode(opts)
      return nil if %w[none source both].include?(mode)

      opts.sub_lang.presence || opts.slang
    end

    def provided_subtitle(zipper)
      if (provided = zipper.opts.subtitle)
        unless provided.is_a?(Subtitler::Subtitle)
          raise TypeError, 'opts.subtitle must be a Subtitler::Subtitle'
        end
        subtitle = provided
      elsif (provided = zipper.opts.sub_vtt).present?
        subtitle = Subtitler::Subtitle.from_vtt(Subtitler::VTT.clean(provided.to_s))
        subtitle.replace_language!(zipper.opts.sub_lang.presence || zipper.opts.slang || 'mul')
      else
        return
      end

      normalize_language!(subtitle)
      subtitle
    end

    def fetch(zipper)
      subtitles = zipper.info&.subtitles
      return fetch_scraped(zipper, subtitles) if subtitles.present?

      fetch_embedded(zipper)
    end

    def fetch_scraped(zipper, subtitles)
      lang = preferred_lang(zipper, subtitles)
      return unless lang

      entry = subtitles[lang].find { |sub| sub.ext == 'vtt' } || subtitles[lang].first
      body  = Utils::HTTP.get_public(entry.url)
      vtt   = Subtitler::VTT.to_vtt body, entry.ext, ffmpeg: zipper.send(:ffmpeg_builder)
      zipper.stl&.update "subs:scraped:#{lang}"
      Subtitler::Subtitle.from_vtt(vtt).replace_language!(Subtitler.normalize_lang(lang) || lang.to_s)
    end

    def fetch_embedded(zipper)
      streams = zipper.probe.streams.select { |s| s.codec_type == 'subtitle' }
      return if streams.blank?

      streams.each { |stream| stream.lang = ISO_639.find_by_code(stream.tags.language)&.alpha2 }
      requested = zipper.opts.sub_lang.presence || zipper.opts.slang
      index = streams.index { |stream| subtitle_match?(requested, stream) }
      return unless index

      vtt = Subtitler::VTT.extract_embedded zipper, index, ffmpeg: zipper.send(:ffmpeg_builder)
      lang = streams[index].lang
      zipper.stl&.update "subs:embedded:#{lang}"
      Subtitler::Subtitle.from_vtt(vtt).replace_language!(lang)
    end

    def preferred_lang(zipper, subtitles)
      requested = zipper.opts.sub_lang.presence || zipper.opts.slang
      keys      = subtitles.keys
      exact     = keys.find { |code| requested.present? && code.to_s.casecmp?(requested.to_s) }
      requested = Subtitler.normalize_lang(requested)
      locale    = keys.find { |code| requested && Subtitler.normalize_lang(code) == requested }
      exact || locale || keys.find { |code| code.to_s.downcase == 'en' } || keys.first
    end

    def subtitle_match?(desired, stream)
      desired.present? && desired.in?([stream.lang, stream.tags.language, stream.tags.title])
    end

    def normalize_language!(subtitle)
      language = Subtitler.normalize_lang(subtitle.language) || subtitle.language
      subtitle.replace_language!(language)
    end

    def translate_if_needed(zipper, subtitle, target_language)
      from = Subtitler.normalize_lang(subtitle.language)
      to   = Subtitler.normalize_lang(target_language)
      return subtitle unless to
      return subtitle if from && from == to

      zipper.stl&.update 'translating'
      subtitle.translated(from: from, to: to, merge_adjacent: false)
    end

    private :subtitles_requested?, :provided_subtitle, :fetch, :fetch_scraped,
            :fetch_embedded, :preferred_lang, :subtitle_match?, :normalize_language!, :translate_if_needed
    private :safe_ass_prefix
  end
end
