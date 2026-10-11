module Dubbing
  class Pipeline
    # The translated subtitles a dub is made from, and the ones it leaves behind.
    module Subtitles
      private

      def translated_sentences(subtitle)
        sentences = subtitle.sentence_entries
        texts     = sentences.map(&:text)
        translations = if ::Translator.respond_to?(:translate_for_dubbing)
          Array(::Translator.translate_for_dubbing(texts, from: source_lang, to: target_lang))
        else
          Array(::Translator.translate(texts, from: source_lang, to: target_lang))
        end

        sentences.zip(translations).filter_map do |sentence, translated|
          text = Subtitler::Subtitle.clean_translation(translated)
          next if text.empty?

          translated_entry(sentence, text)
        end
      end

      def translated_entry(sentence, text)
        sentence.deep_copy
          .replace_source!(text: sentence.text.strip, words: sentence.words.map(&:deep_copy))
          .project_text!(text)
      end

      def prepare_translated_subtitles
        mode = @opts.sub_mode.to_s
        return if mode == 'none'
        return unless @opts.gensubs || mode.present?

        case mode
        when 'source'
          @opts.subtitle = source_subtitle
          @opts.sub_lang = source_lang
        when 'both'
          @opts.subtitle = bilingual_subtitle
          @opts.sub_lang = 'mul'
        when 'language'
          target_language = subtitle_target_lang == target_lang
          subtitle        = target_language ? target_subtitle : alternate_subtitle
          @opts.subtitle = prepare_subtitle(subtitle, normalize: target_language)
          @opts.sub_lang = subtitle_target_lang
        else
          @opts.subtitle = prepare_subtitle(target_subtitle)
          @opts.sub_lang = target_lang
        end
      end

      def target_subtitle
        Subtitler::Subtitle.new(language: target_lang, entries: @sentences.map(&:deep_copy))
      end

      def source_subtitle
        (@transcript_output || Subtitler::Subtitle.new).deep_copy
      end

      def alternate_subtitle
        target_subtitle.translated(
          from:           target_lang,
          to:             subtitle_target_lang,
          merge_adjacent: false
        )
      end

      def bilingual_subtitle
        entries = @sentences.map do |sentence|
          texts = [sentence.source_text, sentence.text].map { |text| text.to_s.strip }.reject(&:empty?).uniq
          Subtitler::Subtitle::Entry.new(
            text: texts.join("\n"), start: sentence.start, finish: sentence.finish, speaker_id: sentence.speaker_id
          )
        end
        Subtitler::Subtitle.new(language: 'mul', entries: entries)
      end

      def prepare_subtitle(subtitle, normalize: true)
        subtitle.normalize_entries! if normalize
        subtitle
      end

      def replace_sentences!(sentences)
        @sentences = sentences
      end

      def subtitle_target_lang
        @opts.sub_lang.presence || target_lang
      end
    end
  end
end
