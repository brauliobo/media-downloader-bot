require_relative 'subtitle'

class Subtitler
  class Translator
    MAX_SUBTITLE_CHARS = Subtitle::MAX_ENTRY_CHARS

    def self.clean_translation(text)
      Subtitle.clean_translation(text)
    end

    def self.translate(subtitle, **options)
      require_subtitle!(subtitle)
      subtitle.translated(**options)
    end

    def self.sentences_for(value)
      subtitle = if value.is_a?(Subtitle)
        value
      elsif value.is_a?(Array) && value.all? { |entry| entry.is_a?(Subtitle::Entry) }
        Subtitle.new(entries: value)
      else
        raise TypeError, 'value must be a Subtitle or an Array of Subtitle::Entry objects'
      end
      subtitle.sentence_entries
    end

    def self.split_long_segments!(subtitle, max_chars: MAX_SUBTITLE_CHARS)
      require_subtitle!(subtitle)
      subtitle.split_long_entries!(max_chars: max_chars)
    end

    def self.tokenize_text(text)
      Subtitle.tokenize(text)
    end

    def self.assign_tokens_to_words!(entry, tokens)
      unless entry.is_a?(Subtitle::Entry)
        raise TypeError, 'entry must be a Subtitler::Subtitle::Entry'
      end

      entry.project_tokens!(tokens)
    end

    def self.require_subtitle!(subtitle)
      raise TypeError, 'subtitle must be a Subtitler::Subtitle' unless subtitle.is_a?(Subtitle)
    end
    private_class_method :require_subtitle!
  end
end
