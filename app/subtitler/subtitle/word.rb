class Subtitler
  class Subtitle
    class Word
      CONFIDENCE_KEYS = %w[confidence probability prob p].freeze

      attr_reader :text, :start, :finish, :confidence, :metadata

      def self.from_whisper(data)
        data = Types.json_object(data, 'word')

        new(
          text:       data.fetch('word'),
          start:      data.fetch('start'),
          finish:     data.fetch('end'),
          confidence: confidence_from(data),
          metadata:   Types.metadata_from(data, %w[word start end])
        )
      end

      def self.from_transcribe_cpp(data)
        data = Types.json_object(data, 'word')

        new(
          text:       data.fetch('text'),
          start:      Types.milliseconds(data.fetch('t0_ms'), 't0_ms'),
          finish:     Types.milliseconds(data.fetch('t1_ms'), 't1_ms'),
          confidence: confidence_from(data),
          metadata:   Types.metadata_from(data, %w[text t0_ms t1_ms])
        )
      end

      def initialize(text:, start:, finish:, confidence: nil, metadata: {})
        @text   = Types.string(text, 'text')
        @start  = Types.number(start, 'start')
        @finish = Types.number(finish, 'finish')
        raise ArgumentError, 'finish must not precede start' if @finish < @start

        @confidence = confidence.nil? ? nil : Types.number(confidence, 'confidence')
        @metadata   = Types.immutable_hash(metadata, 'metadata')
      end

      def replace_text!(text)
        @text = Types.string(text, 'text')
        self
      end

      def replace_timing!(start:, finish:)
        retime!(start: start, finish: finish)
      end

      def retime!(start:, finish:)
        new_start  = Types.number(start, 'start')
        new_finish = Types.number(finish, 'finish')
        raise ArgumentError, 'finish must not precede start' if new_finish < new_start

        @start  = new_start
        @finish = new_finish
        self
      end

      def scale_timing!(factor)
        factor = Types.number(factor, 'factor')
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
          metadata:   Types.mutable_copy(@metadata)
        )
      end

      def merge!(other)
        raise TypeError, 'other must be a Subtitle::Word' unless other.is_a?(self.class)

        @text       = "#{@text}#{other.text}".freeze
        @start      = [@start, other.start].min
        @finish     = [@finish, other.finish].max
        @confidence = [@confidence, other.confidence].compact.min
        @metadata   = Types.immutable_hash(Types.mutable_copy(@metadata).merge(
          Types.mutable_copy(other.metadata)
        ), 'metadata')
        self
      end

      def self.confidence_from(data)
        key = CONFIDENCE_KEYS.find { |candidate| data.key?(candidate) }
        key && data[key]
      end
      private_class_method :confidence_from

    end
  end
end
