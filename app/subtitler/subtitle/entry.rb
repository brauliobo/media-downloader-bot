class Subtitler
  class Subtitle
    class Entry
      UNSPECIFIED = Object.new.freeze

      attr_reader :start, :finish, :text, :words, :speaker_id, :cue_id, :source_text, :source_words, :metadata

      def self.assert_all!(values, name)
        unless values.is_a?(Array) && values.all? { |value| value.is_a?(self) }
          raise TypeError, "#{name} must contain only Subtitler::Subtitle::Entry objects"
        end

        values
      end

      def self.from_whisper(data)
        data  = Types.json_object(data, 'segment')
        words = Types.optional_array(data['words'], 'words').map { |word| Word.from_whisper(word) }

        new(
          start:      data.fetch('start'),
          finish:     data.fetch('end'),
          text:       data['text'],
          words:      words,
          speaker_id: data['speaker_id'],
          cue_id:     data['cue_id'],
          metadata:   Types.metadata_from(data, %w[start end text words speaker_id cue_id])
        )
      end

      def self.from_transcribe_cpp(data)
        data  = Types.json_object(data, 'segment')
        words = Types.optional_array(data['words'], 'words').map { |word| Word.from_transcribe_cpp(word) }

        new(
          start:      Types.milliseconds(data.fetch('t0_ms'), 't0_ms'),
          finish:     Types.milliseconds(data.fetch('t1_ms'), 't1_ms'),
          text:       data['text'],
          words:      words,
          speaker_id: data['speaker_id'],
          cue_id:     data['cue_id'],
          metadata:   Types.metadata_from(data, %w[t0_ms t1_ms text words speaker_id cue_id])
        )
      end

      def initialize(start:, finish:, text: nil, words: nil, speaker_id: nil, cue_id: nil,
        source_text: UNSPECIFIED, source_words: UNSPECIFIED, metadata: {})
        @start  = Types.number(start, 'start')
        @finish = Types.number(finish, 'finish')
        validate_timing!(@start, @finish)

        @text       = Types.optional_text(text, 'text')
        @words      = Types.typed_array(words || [], Word, 'words')
        @speaker_id = speaker_id
        @cue_id     = cue_id
        @source_text  = source_text.equal?(UNSPECIFIED) ? @text : Types.optional_text(source_text, 'source_text')
        source_words = @words.map(&:deep_copy) if source_words.equal?(UNSPECIFIED)
        @source_words = Types.typed_array(source_words || [], Word, 'source_words')
        @metadata     = Types.immutable_hash(metadata, 'metadata')
      end

      def replace_text!(text)
        new_text = Types.optional_text(text, 'text')
        changed = @text != new_text
        @text = new_text
        invalidate_format_text! if changed
        self
      end

      def replace_words!(words)
        @words = Types.typed_array(words || [], Word, 'words')
        self
      end

      def replace_metadata!(metadata)
        @metadata = Types.immutable_hash(metadata, 'metadata')
        self
      end

      def replace_source!(text:, words:)
        @source_text  = Types.optional_text(text, 'source_text')
        @source_words = Types.typed_array(words || [], Word, 'source_words')
        self
      end

      def rebuild_text_from_words!
        new_text = @words.map { |word| word.text.strip }.reject(&:empty?).join(' ').freeze
        changed = @text != new_text
        @text = new_text
        invalidate_format_text! if changed
        self
      end

      def replace_timing!(start:, finish:)
        new_start  = Types.number(start, 'start')
        new_finish = Types.number(finish, 'finish')
        validate_timing!(new_start, new_finish)
        @start  = new_start
        @finish = new_finish
        self
      end

      def retime!(start:, finish:)
        new_start  = Types.number(start, 'start')
        new_finish = Types.number(finish, 'finish')
        validate_timing!(new_start, new_finish)

        duration       = @finish - @start
        scale          = duration.zero? ? 0.0 : (new_finish - new_start) / duration
        original_start = @start
        (@words + @source_words).uniq(&:object_id).each do |word|
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
        factor = Types.number(factor, 'factor')
        raise ArgumentError, 'factor must not be negative' if factor.negative?

        @start  *= factor
        @finish *= factor
        (@words + @source_words).uniq(&:object_id).each { |word| word.scale_timing!(factor) }
        self
      end

      def assign_speaker!(speaker_id)
        @speaker_id = speaker_id
        self
      end

      def assign_cue!(cue_id)
        @cue_id = cue_id
        self
      end

      def merge_split_words!
        merged = []
        @words.each do |word|
          if merged.empty? || word.text.start_with?(' ') || merged.last.text.strip.match?(/[.!?]$/)
            merged << word
          else
            merged.last.merge!(word)
          end
        end
        replace_words!(merged)
        rebuild_text_from_words! unless @words.empty?
      end

      def project_text!(text)
        replace_text!(text)
        project_tokens!(Subtitle.tokenize(@text)) unless @words.empty?
        rebuild_text_from_words! unless @words.empty?
        self
      end

      def project_tokens!(tokens)
        source = @words.select { |word| word.finish > word.start }
        tokens = Types.typed_array(tokens, String, 'tokens')
        return replace_words!([]) if source.empty? || tokens.empty?

        projected = if tokens.size == source.size
          source.zip(tokens).map { |word, token| word.deep_copy.replace_text!(token) }
        elsif tokens.size > source.size
          project_more_tokens(source, tokens)
        else
          project_fewer_tokens(source, tokens)
        end
        replace_words!(projected)
      end

      def merge!(other)
        raise TypeError, 'other must be a Subtitle::Entry' unless other.is_a?(self.class)

        @start        = [@start, other.start].min
        @finish       = [@finish, other.finish].max
        @text         = join_text(@text, other.text)
        @words        = (@words + other.words.map(&:deep_copy)).freeze
        @source_text  = join_text(@source_text, other.source_text)
        @source_words = (@source_words + other.source_words.map(&:deep_copy)).freeze
        @speaker_id   = other.speaker_id if @speaker_id.nil?
        metadata = Types.mutable_copy(@metadata).merge(
          Types.mutable_copy(other.metadata)
        )
        metadata.reject! { |key, _| Subtitle::RAW_CUE_METADATA_KEYS.include?(key.to_s) }
        @metadata = Types.immutable_hash(metadata, 'metadata')
        self
      end

      def deep_copy
        self.class.new(
          start:        @start,
          finish:       @finish,
          text:         @text,
          words:        @words.map(&:deep_copy),
          speaker_id:   @speaker_id,
          cue_id:       @cue_id,
          source_text:  @source_text,
          source_words: @source_words.map(&:deep_copy),
          metadata:     Types.mutable_copy(@metadata)
        )
      end


      private

      def invalidate_format_text!
        metadata = Types.mutable_copy(@metadata)
        metadata.reject! { |key, _| Subtitle::FORMAT_TEXT_METADATA_KEYS.include?(key.to_s) }
        replace_metadata!(metadata)
      end

      def validate_timing!(start, finish)
        raise ArgumentError, 'finish must not precede start' if finish < start
      end

      def join_text(left, right)
        [left.strip, right.strip].reject(&:empty?).join(' ').freeze
      end

      def project_more_tokens(source, tokens)
        base, extra = tokens.size.divmod(source.size)
        cursor      = 0
        source.flat_map.with_index do |word, index|
          count    = base + (index < extra ? 1 : 0)
          duration = word.finish - word.start
          items    = tokens[cursor, count].map.with_index do |token, token_index|
            start_time  = word.start + duration * token_index / count
            finish_time = token_index == count - 1 ? word.finish : word.start + duration * (token_index + 1) / count
            word.deep_copy.replace_text!(token).retime!(start: start_time, finish: finish_time)
          end
          cursor += count
          items
        end
      end

      def project_fewer_tokens(source, tokens)
        base, extra = source.size.divmod(tokens.size)
        cursor      = 0
        tokens.map.with_index do |token, index|
          count = base + (index < extra ? 1 : 0)
          words = source[cursor, count]
          cursor += count
          words.first.deep_copy.replace_text!(token).replace_timing!(start: words.first.start, finish: words.last.finish)
        end
      end
    end
  end
end
