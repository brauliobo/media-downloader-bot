module Audiobook
  class Runner
    # The voice the book is read in: its reference, instruction and the backend settings that go with it.
    #
    # The reference is recorded when the caller gives a voice (a link or a speaker_wav); only without one is it an
    # Anchor, made up from the voice instruction so the whole book keeps the same narrator.
    module Voice
      VOICE_REFERENCE_WORDS = 12..24

      VOICE_REFERENCE_MAX_CHARS = 240

      private

      def tts_options(dir)
        options = TTS::Options.for(tts_config)
        if @opts&.position_temperature.present?
          options[:position_temperature] = @opts.position_temperature.to_f
        end
        options[:audio_speed] = audio_speed if audio_speed
        return options unless reference_voice?

        recorded = recorded_voice(dir)
        options[:instruct] ||= detected_voice_instruct unless recorded
        options.merge((recorded || anchor_voice(options, dir)).tts_options)
      end

      def recorded_voice(dir)
        recorded_voice_from_url(dir) || recorded_voice_from_file
      end

      def recorded_voice_from_url(dir)
        return unless voice_url

        path = reference_path(dir)
        reference_options = {url: voice_url, output: path, language: @lang, reference_filter: :clone}
        reference_options[:on_status] = @stl.method(:update) if @stl
        TTS::Reference.new(path: path, text: ::VoiceReference.from_url(**reference_options).text)
      end

      def recorded_voice_from_file
        return unless @opts&.speaker_wav.present?

        TTS::Reference.new(path: File.expand_path(@opts.speaker_wav), text: @opts.ref_text.to_s.strip)
      end

      def anchor_voice(options, dir)
        TTS::Anchor.call(text: voice_reference_text, lang: @lang, path: reference_path(dir), **options.except(:audio_speed))
      end

      def reference_path(dir) = File.join(dir, 'audiobook_voice_reference.wav')

      def voice_reference_text
        @voice_reference_text ||= source_voice_reference_text || Language.voice_reference_text(@lang)
      end

      def source_voice_reference_text
        return if @book.try(:translation_needed?) && !@book.translated

        @book.pages.flat_map(&:all_sentences).filter_map do |sentence|
          text = sentence.text.to_s.strip
          words = text.split
          next unless VOICE_REFERENCE_WORDS.cover?(words.size)
          next if text.length > VOICE_REFERENCE_MAX_CHARS

          text
        end.max_by { |text| text.split.size }
      end

      def detected_voice_instruct
        return if voice_instruct.present?

        "#{author_gender}, middle-aged, moderate pitch"
      end

      def author_gender
        @author_gender ||= @book.try(:author_gender).presence || 'male'
      end

      def reference_voice?
        backend_supports?(:reference_voice)
      end

      def backend_supports?(feature)
        TTS.supports?(feature)
      end

      def voice_instruct
        TTS::Options.for(tts_config)[:instruct].to_s
      end

      def voice_url
        value = @opts&.voice.to_s.strip
        value if value.match?(%r{\Ahttps?://}i)
      end

      def tts_config
        return @opts unless voice_url

        SymMash.new(@opts).tap { |options| options.delete(:voice) }
      end
    end
  end
end
