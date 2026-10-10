class Subtitler
  class Subtitle
    class Word
      CONFIDENCE_KEYS = %w[confidence probability prob p].freeze

      attr_reader :text, :start, :finish, :confidence, :metadata

      def self.from_whisper(data)

        new(
          text:       data.fetch('word'),
          start:      data.fetch('start'),
          finish:     data.fetch('end'),
          confidence: confidence_from(data),
          metadata:   Values.metadata_from(data, %w[word start end])
        )
      end

      def self.from_transcribe_cpp(data)

        new(
          text:       data.fetch('text'),
          start:      Values.milliseconds(data.fetch('t0_ms'), 't0_ms'),
          finish:     Values.milliseconds(data.fetch('t1_ms'), 't1_ms'),
          confidence: confidence_from(data),
          metadata:   Values.metadata_from(data, %w[text t0_ms t1_ms])
        )
      end

      def initialize(text:, start:, finish:, confidence: nil, metadata: {})
        @text   = Values.text(text)
        @start  = Values.number(start, 'start')
        @finish = Values.number(finish, 'finish')
        raise ArgumentError, 'finish must not precede start' if @finish < @start

        @confidence = confidence.nil? ? nil : Values.number(confidence, 'confidence')
        @metadata   = Values.immutable_copy(metadata)
      end

      def replace_text!(text)
        @text = Values.text(text)
        self
      end

      def replace_timing!(start:, finish:)
        retime!(start: start, finish: finish)
      end

      def retime!(start:, finish:)
        new_start  = Values.number(start, 'start')
        new_finish = Values.number(finish, 'finish')
        raise ArgumentError, 'finish must not precede start' if new_finish < new_start

        @start  = new_start
        @finish = new_finish
        self
      end

      def scale_timing!(factor)
        factor = Values.number(factor, 'factor')
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
          metadata:   Values.mutable_copy(@metadata)
        )
      end

      def merge!(other)
        @text       = "#{@text}#{other.text}".freeze
        @start      = [@start, other.start].min
        @finish     = [@finish, other.finish].max
        @confidence = [@confidence, other.confidence].compact.min
        @metadata   = Values.immutable_copy(Values.mutable_copy(@metadata).merge(Values.mutable_copy(other.metadata)))
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
