module Dubbing
  class Pipeline
    # The translated subtitles a dub is made from, and the ones it leaves behind.
    module Subtitles
      private

      # Copies of the transcript's sentences, each remembering its source words for when it is translated.
      def source_sentences(subtitle)
        subtitle.sentence_entries.map do |sentence|
          sentence.deep_copy.replace_source!(text: sentence.text.strip, words: sentence.words.map(&:deep_copy))
        end
      end

      # The sentence put into the target language in place. Returns what is to be spoken: blank when there is no translation.
      def translate_sentence!(sentence)
        method = ::Translator.respond_to?(:translate_for_dubbing) ? :translate_for_dubbing : :translate
        text   = Subtitler::Subtitle.clean_translation(::Translator.public_send(method, [sentence.text], from: source_lang, to: target_lang).first)
        text.empty? ? text : sentence.project_text!(text).text
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
          merge_adjacent: false,
          status:         @stl
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
