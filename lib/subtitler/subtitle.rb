require 'json'

class Subtitler
  class Subtitle
    attr_reader :language, :text, :entries, :metadata

    def self.from_whisper_verbose_json(input)
      data = parse_json_object(input)

      new(
        language: data.fetch('language'),
        text:     data.fetch('text'),
        entries:  fetch_array(data, 'segments').map { |entry| Entry.from_whisper(entry) },
        metadata: metadata_from(data, %w[language text segments])
      )
    end

    def self.from_transcribe_cpp_json(input)
      data = parse_json_object(input)

      new(
        language: data.fetch('language'),
        text:     data.fetch('text'),
        entries:  fetch_array(data, 'segments').map { |entry| Entry.from_transcribe_cpp(entry) },
        metadata: metadata_from(data, %w[language text segments])
      )
    end

    def initialize(language:, text:, entries:, metadata: {})
      @language = self.class.send(:optional_string, language, 'language')
      @text     = self.class.send(:string, text, 'text')
      @entries  = self.class.send(:typed_array, entries, Entry, 'entries')
      @metadata = self.class.send(:immutable_hash, metadata, 'metadata')
    end

    def replace_text!(text)
      @text = self.class.send(:string, text, 'text')
      self
    end

    def scale_timing!(factor)
      factor = self.class.send(:number, factor, 'factor')
      raise ArgumentError, 'factor must not be negative' if factor.negative?

      @entries.each { |entry| entry.scale_timing!(factor) }
      self
    end

    def assign_speaker!(speaker_id)
      @entries.each { |entry| entry.assign_speaker!(speaker_id) }
      self
    end

    def deep_copy
      self.class.new(
        language: @language,
        text:     @text,
        entries:  @entries.map(&:deep_copy),
        metadata: self.class.send(:mutable_copy, @metadata)
      )
    end

    def to_whisper_verbose_hash
      self.class.send(:mutable_copy, @metadata).merge(
        'language' => @language,
        'text'     => @text,
        'segments' => @entries.map(&:to_whisper_hash)
      )
    end

    def to_transcribe_cpp_hash
      self.class.send(:mutable_copy, @metadata).merge(
        'language' => @language,
        'text'     => @text,
        'segments' => @entries.map(&:to_transcribe_cpp_hash)
      )
    end

    class Entry
      attr_reader :start, :finish, :text, :words, :speaker_id, :cue_id, :metadata

      def self.from_whisper(data)
        data = Subtitle.send(:json_object, data, 'segment')

        new(
          start:      data.fetch('start'),
          finish:     data.fetch('end'),
          text:       data.fetch('text'),
          words:      Subtitle.send(:fetch_array, data, 'words').map { |word| Word.from_whisper(word) },
          speaker_id: data['speaker_id'],
          cue_id:     data['cue_id'],
          metadata:   Subtitle.send(:metadata_from, data, %w[start end text words speaker_id cue_id])
        )
      end

      def self.from_transcribe_cpp(data)
        data = Subtitle.send(:json_object, data, 'segment')

        new(
          start:      milliseconds(data.fetch('t0_ms'), 't0_ms'),
          finish:     milliseconds(data.fetch('t1_ms'), 't1_ms'),
          text:       data.fetch('text'),
          words:      Subtitle.send(:fetch_array, data, 'words').map { |word| Word.from_transcribe_cpp(word) },
          speaker_id: data['speaker_id'],
          cue_id:     data['cue_id'],
          metadata:   Subtitle.send(:metadata_from, data, %w[t0_ms t1_ms text words speaker_id cue_id])
        )
      end

      def initialize(start:, finish:, text:, words: [], speaker_id: nil, cue_id: nil, metadata: {})
        @start      = Subtitle.send(:number, start, 'start')
        @finish     = Subtitle.send(:number, finish, 'finish')
        raise ArgumentError, 'finish must not precede start' if @finish < @start

        @text       = Subtitle.send(:string, text, 'text')
        @words      = Subtitle.send(:typed_array, words, Word, 'words')
        @speaker_id = speaker_id
        @cue_id     = cue_id
        @metadata   = Subtitle.send(:immutable_hash, metadata, 'metadata')
      end

      def replace_text!(text)
        @text = Subtitle.send(:string, text, 'text')
        self
      end

      def replace_words!(words)
        @words = Subtitle.send(:typed_array, words, Word, 'words')
        self
      end

      def rebuild_text_from_words!
        @text = @words.map { |word| word.text.strip }.reject(&:empty?).join(' ').freeze
        self
      end

      def retime!(start:, finish:)
        new_start  = Subtitle.send(:number, start, 'start')
        new_finish = Subtitle.send(:number, finish, 'finish')
        raise ArgumentError, 'finish must not precede start' if new_finish < new_start

        duration     = @finish - @start
        scale        = duration.zero? ? 0.0 : (new_finish - new_start) / duration
        original_start = @start
        @words.each do |word|
          word.retime!(
            start:  new_start + ((word.start - original_start) * scale),
            finish: new_start + ((word.finish - original_start) * scale)
          )
        end
        @start  = new_start
        @finish = new_finish
        self
      end

      def scale_timing!(factor)
        factor = Subtitle.send(:number, factor, 'factor')
        raise ArgumentError, 'factor must not be negative' if factor.negative?

        @start  *= factor
        @finish *= factor
        @words.each { |word| word.scale_timing!(factor) }
        self
      end

      def assign_speaker!(speaker_id)
        @speaker_id = speaker_id
        self
      end

      def merge!(other)
        raise TypeError, 'other must be a Subtitle::Entry' unless other.is_a?(self.class)

        @start      = [@start, other.start].min
        @finish     = [@finish, other.finish].max
        @text       = [@text.strip, other.text.strip].reject(&:empty?).join(' ').freeze
        @words      = (@words + other.words.map(&:deep_copy)).freeze
        @speaker_id = other.speaker_id if @speaker_id.nil?
        @metadata   = Subtitle.send(:immutable_hash, Subtitle.send(:mutable_copy, @metadata).merge(
          Subtitle.send(:mutable_copy, other.metadata)
        ), 'metadata')
        self
      end

      def deep_copy
        self.class.new(
          start:      @start,
          finish:     @finish,
          text:       @text,
          words:      @words.map(&:deep_copy),
          speaker_id: @speaker_id,
          cue_id:     @cue_id,
          metadata:   Subtitle.send(:mutable_copy, @metadata)
        )
      end

      def to_whisper_hash
        Subtitle.send(:mutable_copy, @metadata).merge(
          'start' => @start,
          'end'   => @finish,
          'text'  => @text,
          'words' => @words.map(&:to_whisper_hash)
        ).tap do |data|
          data['speaker_id'] = @speaker_id unless @speaker_id.nil?
          data['cue_id']     = @cue_id unless @cue_id.nil?
        end
      end

      def to_transcribe_cpp_hash
        Subtitle.send(:mutable_copy, @metadata).merge(
          't0_ms' => (@start * 1000).round,
          't1_ms' => (@finish * 1000).round,
          'text'  => @text,
          'words' => @words.map(&:to_transcribe_cpp_hash)
        ).tap do |data|
          data['speaker_id'] = @speaker_id unless @speaker_id.nil?
          data['cue_id']     = @cue_id unless @cue_id.nil?
        end
      end

      def self.milliseconds(value, field)
        Subtitle.send(:number, value, field) / 1000.0
      end
      private_class_method :milliseconds
    end

    class Word
      CONFIDENCE_KEYS = %w[confidence probability prob p].freeze

      attr_reader :text, :start, :finish, :confidence, :metadata

      def self.from_whisper(data)
        data = Subtitle.send(:json_object, data, 'word')

        new(
          text:       data.fetch('word'),
          start:      data.fetch('start'),
          finish:     data.fetch('end'),
          confidence: confidence_from(data),
          metadata:   Subtitle.send(:metadata_from, data, %w[word start end])
        )
      end

      def self.from_transcribe_cpp(data)
        data = Subtitle.send(:json_object, data, 'word')

        new(
          text:       data.fetch('text'),
          start:      Entry.send(:milliseconds, data.fetch('t0_ms'), 't0_ms'),
          finish:     Entry.send(:milliseconds, data.fetch('t1_ms'), 't1_ms'),
          confidence: confidence_from(data),
          metadata:   Subtitle.send(:metadata_from, data, %w[text t0_ms t1_ms])
        )
      end

      def initialize(text:, start:, finish:, confidence: nil, metadata: {})
        @text       = Subtitle.send(:string, text, 'text')
        @start      = Subtitle.send(:number, start, 'start')
        @finish     = Subtitle.send(:number, finish, 'finish')
        raise ArgumentError, 'finish must not precede start' if @finish < @start

        @confidence = confidence.nil? ? nil : Subtitle.send(:number, confidence, 'confidence')
        @metadata   = Subtitle.send(:immutable_hash, metadata, 'metadata')
      end

      def replace_text!(text)
        @text = Subtitle.send(:string, text, 'text')
        self
      end

      def retime!(start:, finish:)
        new_start  = Subtitle.send(:number, start, 'start')
        new_finish = Subtitle.send(:number, finish, 'finish')
        raise ArgumentError, 'finish must not precede start' if new_finish < new_start

        @start  = new_start
        @finish = new_finish
        self
      end

      def scale_timing!(factor)
        factor = Subtitle.send(:number, factor, 'factor')
        raise ArgumentError, 'factor must not be negative' if factor.negative?

        @start  *= factor
        @finish *= factor
        self
      end

      def deep_copy
        self.class.new(
          text:       @text,
          start:      @start,
          finish:     @finish,
          confidence: @confidence,
          metadata:   Subtitle.send(:mutable_copy, @metadata)
        )
      end

      def merge!(other)
        raise TypeError, 'other must be a Subtitle::Word' unless other.is_a?(self.class)

        @text       = "#{@text}#{other.text}".freeze
        @start      = [@start, other.start].min
        @finish     = [@finish, other.finish].max
        @confidence = [@confidence, other.confidence].compact.min
        @metadata   = Subtitle.send(:immutable_hash, Subtitle.send(:mutable_copy, @metadata).merge(
          Subtitle.send(:mutable_copy, other.metadata)
        ), 'metadata')
        self
      end

      def to_whisper_hash
        external_hash('word', 'start', 'end', @start, @finish)
      end

      def to_transcribe_cpp_hash
        external_hash('text', 't0_ms', 't1_ms', (@start * 1000).round, (@finish * 1000).round)
      end

      def self.confidence_from(data)
        key = CONFIDENCE_KEYS.find { |candidate| data.key?(candidate) }
        key && data[key]
      end
      private_class_method :confidence_from

      private

      def external_hash(text_key, start_key, finish_key, start_value, finish_value)
        Subtitle.send(:mutable_copy, @metadata).merge(
          text_key   => @text,
          start_key  => start_value,
          finish_key => finish_value
        ).tap do |data|
          unless @confidence.nil? || CONFIDENCE_KEYS.any? { |key| data.key?(key) }
            data['confidence'] = @confidence
          end
        end
      end
    end

    class << self
      private

      def parse_json_object(input)
        input = JSON.parse(input) if input.is_a?(String)
        json_object(input, 'subtitle')
      rescue JSON::ParserError => error
        raise ArgumentError, "invalid subtitle JSON: #{error.message}"
      end

      def json_object(value, field)
        raise TypeError, "#{field} must be a Hash" unless value.is_a?(Hash)
        raise ArgumentError, "#{field} keys must be strings" unless value.keys.all? { |key| key.is_a?(String) }

        value
      end

      def fetch_array(data, field)
        value = data.fetch(field)
        raise TypeError, "#{field} must be an Array" unless value.is_a?(Array)

        value
      end

      def metadata_from(data, known_keys)
        data.reject { |key, _| known_keys.include?(key) }
      end

      def optional_string(value, field)
        return if value.nil?

        string(value, field)
      end

      def string(value, field)
        raise TypeError, "#{field} must be a String" unless value.is_a?(String)

        value.dup.freeze
      end

      def number(value, field)
        raise TypeError, "#{field} must be Numeric" unless value.is_a?(Numeric)
        raise ArgumentError, "#{field} must be finite" unless value.finite?

        value.to_f
      end

      def typed_array(value, type, field)
        raise TypeError, "#{field} must be an Array" unless value.is_a?(Array)
        raise TypeError, "#{field} must contain only #{type}" unless value.all? { |item| item.is_a?(type) }

        value.dup.freeze
      end

      def immutable_hash(value, field)
        raise TypeError, "#{field} must be a Hash" unless value.is_a?(Hash)

        immutable_copy(value)
      end

      def immutable_copy(value)
        case value
        when Hash
          value.to_h { |key, item| [immutable_copy(key), immutable_copy(item)] }.freeze
        when Array
          value.map { |item| immutable_copy(item) }.freeze
        when String
          value.dup.freeze
        else
          value.freeze
        end
      end

      def mutable_copy(value)
        case value
        when Hash
          value.to_h { |key, item| [mutable_copy(key), mutable_copy(item)] }
        when Array
          value.map { |item| mutable_copy(item) }
        when String
          value.dup
        else
          value
        end
      end
    end
  end
end
