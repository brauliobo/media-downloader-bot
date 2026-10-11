module Audiobook
  class Runner
    # The voice the book is read in: its reference, instruction and the backend settings that go with it.
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
        return options unless stable_voice_reference?

        if voice_url
          ref_path  = File.join(dir, 'audiobook_voice_reference.wav')
          reference_options = {
            url:              voice_url,
            output:           ref_path,
            language:         @lang,
            reference_filter: :clone,
          }
          reference_options[:on_status] = @stl.method(:update) if @stl
          reference = ::VoiceReference.from_url(**reference_options)
          return with_speaker(options, ref_path, reference.text)
        end

        if @opts&.speaker_wav.present?
          return with_speaker(options, File.expand_path(@opts.speaker_wav), @opts.ref_text.to_s.strip)
        end

        options[:instruct] ||= detected_voice_instruct
        ref_path = File.join(dir, 'audiobook_voice_reference.wav')
        reference_options = options.except(:audio_speed)
        unless File.exist?(ref_path) && File.size?(ref_path)
          TTS.synthesize(
            text:     voice_reference_text,
            lang:     @lang,
            out_path: ref_path,
            **reference_options
          )
        end

        with_speaker(options, ref_path, voice_reference_text)
      end

      def with_speaker(options, wav, text)
        options.merge(speaker_wav: wav, ref_text: text)
      end

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

      def stable_voice_reference?
        backend_supports?(:stable_voice_reference)
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
