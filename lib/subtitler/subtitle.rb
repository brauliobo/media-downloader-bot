require 'json'
require 'cgi'
require 'nokogiri'

require_relative '../text_helpers'
require_relative 'timestamps'

class Subtitler
  class Subtitle
    MAX_ENTRY_CHARS    = 84
    TRANSLATION_PREFIX = /\A(?:translation|translated(?:\s+text)?|answer|response)\s*:\s*/i
    NOISE_DOTS_LINE    = /\A\s*\d(?:\s*\.\s*\d){3,}\.??\s*\z/.freeze

    attr_reader :language, :text, :entries, :metadata

    def self.from_whisper_verbose_json(input)
      data = parse_json_object(input)

      new(
        language: data['language'],
        text:     data['text'],
        entries:  fetch_array(data, 'segments').map { |entry| Entry.from_whisper(entry) },
        metadata: metadata_from(data, %w[language text segments])
      )
    end

    def self.from_transcribe_cpp_json(input)
      data = parse_json_object(input)

      new(
        language: data['language'],
        text:     data['text'],
        entries:  fetch_array(data, 'segments').map { |entry| Entry.from_transcribe_cpp(entry) },
        metadata: metadata_from(data, %w[language text segments])
      )
    end

    def self.from_vtt(vtt)
      parse_cues(vtt, format: :vtt)
    end

    def self.from_srt(srt)
      parse_cues(srt, format: :srt)
    end

    def self.tokenize(text)
      raw = optional_text(text, 'text').scan(/\p{L}+[\p{L}\p{M}'’\-]*|\d+|[^\p{L}\d\s]+/)
      raw.each_with_object([]) do |token, tokens|
        if token.match?(/\A[^\p{L}\d\s]+\z/) && tokens.any?
          tokens[-1] = "#{tokens.last}#{token}"
        else
          tokens << token
        end
      end
    end

    def self.clean_translation(text)
      optional_text(text, 'translation').strip.sub(TRANSLATION_PREFIX, '').strip
    end

    def initialize(language: nil, text: nil, entries: [], metadata: {})
      @language = self.class.send(:optional_string, language, 'language')
      @text     = self.class.send(:optional_text, text, 'text')
      @entries  = self.class.send(:typed_array, entries, Entry, 'entries')
      @metadata = self.class.send(:immutable_hash, metadata, 'metadata')
    end

    def replace_language!(language)
      @language = self.class.send(:optional_string, language, 'language')
      self
    end

    def replace_text!(text)
      @text = self.class.send(:optional_text, text, 'text')
      self
    end

    def replace_entries!(entries)
      @entries = self.class.send(:typed_array, entries, Entry, 'entries')
      self
    end

    def reject_entries!(&block)
      raise ArgumentError, 'a block is required' unless block

      replace_entries!(@entries.reject(&block))
    end

    def rebuild_text_from_entries!
      @text = @entries.map { |entry| entry.text.strip }.reject(&:empty?).join(' ').freeze
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

    def merge_split_words!
      @entries.each(&:merge_split_words!)

      index = 1
      while index < @entries.length
        previous = @entries[index - 1]
        current  = @entries[index]

        while merge_cross_entry_word?(previous, current)
          suffix = current.words.first
          previous.words.last.merge!(suffix)
          current.replace_words!(current.words.drop(1))
          previous.replace_timing!(start: previous.start, finish: [previous.finish, suffix.finish].max)
          transfer_leading_source_word!(current, previous)
        end

        previous.rebuild_text_from_words! unless previous.words.empty?
        if current.words.empty?
          remaining = @entries.dup
          remaining.delete_at(index)
          replace_entries!(remaining)
        else
          current.replace_timing!(start: current.words.first.start, finish: [current.finish, current.words.last.finish].max)
          current.rebuild_text_from_words!
          index += 1
        end
      end

      rebuild_text_from_entries!
    end

    def merge_adjacent!(max_chars: MAX_ENTRY_CHARS, gap_threshold: 1.0, respect_speaker: true)
      return self if @entries.empty?

      merged  = []
      current = @entries.first
      @entries.drop(1).each do |entry|
        if mergeable?(current, entry, max_chars, gap_threshold, respect_speaker)
          current.merge!(entry)
        else
          merged << current
          current = entry
        end
      end
      replace_entries!(merged << current)
      rebuild_text_from_entries!
    end

    def sentence_entries
      @entries.chunk_while do |left, right|
        representation_and_boundary(left) == representation_and_boundary(right)
      end.flat_map do |run|
        if run.first.words.any?
          TextHelpers.sentences_from_entries(run.map(&:deep_copy)).each do |entry|
            entry.assign_speaker!(run.first.speaker_id)
            entry.assign_cue!(run.first.cue_id)
            entry.replace_metadata!(self.class.send(:mutable_copy, run.first.metadata))
          end
        else
          run.flat_map { |entry| text_sentence_entries(entry) }
        end
      end.select { |entry| entry.finish > entry.start }
    end

    def split_long_entries!(max_chars: MAX_ENTRY_CHARS)
      replace_entries!(@entries.flat_map { |entry| split_entry(entry, max_chars) })
      rebuild_text_from_entries!
    end

    def normalize_entries!(max_chars: MAX_ENTRY_CHARS, gap_threshold: 1.0, respect_speaker: true)
      split_long_entries!(max_chars: max_chars)
      merge_adjacent!(max_chars: max_chars, gap_threshold: gap_threshold, respect_speaker: respect_speaker)
    end

    def translate!(from:, to:, merge_adjacent: true, translator: nil, batch_size: nil)
      sentences = sentence_entries
      texts     = sentences.map(&:text)
      translated_texts = translate_texts(
        texts, from: from, to: to, translator: translator, batch_size: batch_size
      )

      sentences.zip(translated_texts).each do |entry, translated_text|
        entry.project_text!(self.class.clean_translation(translated_text))
      end
      replace_entries!(sentences)
      split_long_entries!(max_chars: MAX_ENTRY_CHARS)
      merge_adjacent!(max_chars: MAX_ENTRY_CHARS) if merge_adjacent
      replace_language!(to)
      rebuild_text_from_entries!
    end

    def translated(**options)
      deep_copy.translate!(**options)
    end

    def reject_noise!
      rejected_blocks = Array(@metadata['source_blocks']).each_index.select do |index|
        noise_content_lines(@metadata['source_blocks'].fetch(index)).any? do |line|
          line.strip.match?(NOISE_DOTS_LINE)
        end
      end
      reject_entries! do |entry|
        lines = Array(entry.metadata['content_lines'])
        lines.any? { |line| line.strip.match?(NOISE_DOTS_LINE) }
      end
      @metadata = self.class.send(
        :immutable_hash,
        self.class.send(:mutable_copy, @metadata).merge('rejected_block_indices' => rejected_blocks),
        'metadata'
      )
      rebuild_text_from_entries!
    end

    def slice(from:, to:, rebase: true)
      range_start  = self.class.send(:time_value, from, 'from')
      range_finish = self.class.send(:time_value, to, 'to')
      raise ArgumentError, 'to must be greater than from' unless range_finish > range_start

      sliced = @entries.filter_map do |entry|
        next unless entry.finish > range_start && entry.start < range_finish
        next entry.deep_copy unless rebase

        slice_entry(entry, range_start, range_finish)
      end
      self.class.new(
        language: @language,
        text:     sliced.map(&:text).join(' '),
        entries:  sliced,
        metadata: self.class.send(:mutable_copy, @metadata).merge('numbered_cues' => true)
      )
    end

    def to_vtt(word_tags: true)
      render_cues(format: :vtt, word_tags: word_tags)
    end

    def to_srt(word_tags: true)
      render_cues(format: :srt, word_tags: word_tags)
    end

    def to_ass(portrait: false, mode: :instagram, preset: 'default')
      require_relative 'ass'

      Subtitler::Ass.document_for(self, portrait: portrait, mode: mode, preset: preset).to_s
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

    private

    def slice_entry(entry, range_start, range_finish)
      start_time  = [entry.start, range_start].max
      finish_time = [entry.finish, range_finish].min
      words = entry.words.filter_map do |word|
        next unless word.finish > range_start && word.start < range_finish

        word.deep_copy.replace_timing!(
          start:  [word.start, range_start].max - range_start,
          finish: [word.finish, range_finish].min - range_start
        )
      end
      return if entry.words.any? && words.empty?

      text = words.empty? ? entry.text : words.map { |word| word.text.strip }.join(' ')
      Entry.new(
        start:      start_time - range_start,
        finish:     finish_time - range_start,
        text:       text,
        words:      words,
        speaker_id: entry.speaker_id,
        cue_id:     entry.cue_id,
        metadata:   self.class.send(:mutable_copy, entry.metadata).reject { |key, _| key == 'ass_text' }
      )
    end

    def render_cues(format:, word_tags:)
      decimal = format == :srt ? ',' : '.'
      out     = format == :vtt ? +"WEBVTT\n\n" : +''
      newline = format == :srt ? @metadata.fetch('line_ending', "\n") : "\n"
      if format == :srt && word_tags && @metadata['source_blocks'] && @entries.all? { |entry| original_srt_entry?(entry) }
        return render_original_srt_document
      end

      rendered = @entries.filter_map.with_index do |entry, index|
        source_start  = entry.start
        source_finish = entry.finish
        next unless source_finish > source_start

        if format == :srt && word_tags && original_srt_entry?(entry)
          next original_srt_lines(entry).join(newline)
        end

        start_units  = Subtitler.timestamp_units(source_start)
        finish_units = Subtitler.timestamp_units(source_finish)
        finish_units = start_units + 1 if finish_units <= start_units
        start_time   = start_units / 1000.0
        finish_time  = finish_units / 1000.0
        lines        = []
        identifier   = cue_identifier(entry, index, format)
        lines << identifier if identifier
        lines << "#{Subtitler.format_timestamp(start_time, decimal: decimal)} --> #{Subtitler.format_timestamp(finish_time, decimal: decimal)}"
        lines << render_entry_text(entry, start_time, finish_time, decimal, word_tags, format)
        lines.join(newline)
      end

      if format == :vtt
        out << rendered.join("\n\n")
        out << "\n\n" unless rendered.empty?
      else
        out << rendered.join(newline * 2)
        out << newline * @metadata.fetch('final_newlines', rendered.empty? ? 0 : 2)
      end
      out
    end

    def cue_identifier(entry, index, format)
      return (index + 1).to_s if format == :srt && entry.cue_id.nil?
      return entry.cue_id.to_s if format == :srt
      return unless @metadata['numbered_cues']

      (index + 1).to_s
    end

    def render_entry_text(entry, start_time, finish_time, decimal, word_tags, format)
      if format == :vtt && @metadata['source_format'] == 'srt' && original_srt_entry?(entry)
        return entry.metadata.fetch('content_lines').join("\n").gsub(Subtitler::INLINE_TIMESTAMP) do |timestamp|
          timestamp.tr(',', '.')
        end
      end
      return entry.text.strip if entry.words.empty?

      last_marker = nil
      preserve_markers = @metadata['source_format'] == 'srt'
      entry.words.filter_map.with_index do |word, index|
        token = word.text.strip
        next if token.empty?

        marker_units = Subtitler.timestamp_units(word.start)
        marker_time  = marker_units / 1000.0
        tagged = if preserve_markers
          word_tags && word.metadata['marker']
        elsif format == :srt
          word_tags && index.positive?
        else
          word_tags && marker_time >= start_time &&
            (index.positive? || marker_time > start_time) && marker_time < finish_time &&
            (!last_marker || marker_time > last_marker)
        end
        last_marker = marker_time if tagged
        marker = Subtitler.format_timestamp(marker_time, decimal: decimal)
        tagged ? "<#{marker}>#{token}" : token
      end.join(' ')
    end

    def original_srt_entry?(entry)
      entry.metadata['source_start'] == entry.start &&
        entry.metadata['source_finish'] == entry.finish &&
        entry.metadata['source_text'] == entry.text
    end

    def original_srt_lines(entry)
      Array(entry.metadata['prefix_lines']) +
        [entry.metadata.fetch('timing_line')] + entry.metadata.fetch('content_lines')
    end

    def render_original_srt_document
      kept_cues = @entries.map { |entry| entry.metadata.fetch('block_index') }
      cue_blocks = @metadata.fetch('cue_block_indices')
      rejected   = Array(@metadata['rejected_block_indices'])
      @metadata.fetch('source_blocks').filter_map.with_index do |block, index|
        next if rejected.include?(index)
        next if cue_blocks.include?(index) && !kept_cues.include?(index)

        block
      end.join("\n\n")
    end

    def noise_content_lines(block)
      block.lines.reject do |line|
        stripped = line.strip
        stripped.empty? || stripped.match?(/^\d+$/) || line.include?('-->')
      end
    end

    def merge_cross_entry_word?(previous, current)
      return false if previous.words.empty? || current.words.empty?

      !current.words.first.text.start_with?(' ') && !previous.words.last.text.strip.match?(/[.!?]$/)
    end

    def transfer_leading_source_word!(source, target)
      moved = source.source_words.first
      return unless moved

      target_words = target.source_words + [moved.deep_copy]
      source_words = source.source_words.drop(1)
      target.replace_source!(text: source_text_from(target_words), words: target_words)
      source.replace_source!(text: source_text_from(source_words), words: source_words)
    end

    def source_text_from(words)
      words.map(&:text).join.strip
    end

    def mergeable?(left, right, max_chars, gap_threshold, respect_speaker)
      if respect_speaker && !left.speaker_id.nil? && !right.speaker_id.nil? && left.speaker_id != right.speaker_id
        return false
      end

      gap      = right.start - left.finish
      combined = left.text.length + 1 + right.text.length
      gap <= gap_threshold && combined <= max_chars
    end

    def representation_and_boundary(entry)
      [entry.words.any?, entry.cue_id, entry.speaker_id]
    end

    def text_sentence_entries(entry)
      parts = TextHelpers.split_sentences(entry.text.strip)
      return [] if parts.empty?
      return [entry.deep_copy] if parts.size == 1

      build_text_entries(entry, parts, partition_source: true)
    end

    def split_entry(entry, max_chars)
      return [entry] if entry.text.strip.length <= max_chars

      words = entry.words.reject { |word| word.text.strip.empty? }
      if words.empty?
        parts = split_items(entry.text.strip.split(/\s+/), max_chars) { |token| token }
        return [entry] if parts.size <= 1

        build_text_entries(entry, parts.map { |part| part.join(' ') })
      else
        split_items(words, max_chars) { |word| word.text.strip }.map do |chunk|
          build_word_entry(entry, chunk)
        end
      end
    end

    def build_word_entry(source, words)
      copies = words.map(&:deep_copy)
      Entry.new(
        start:        copies.first.start,
        finish:       copies.last.finish,
        text:         copies.map { |word| word.text.strip }.join(' '),
        words:        copies,
        speaker_id:   source.speaker_id,
        cue_id:       source.cue_id,
        source_text:  source.source_text,
        source_words: source.source_words.map(&:deep_copy),
        metadata:     self.class.send(:mutable_copy, source.metadata)
      )
    end

    def build_text_entries(source, texts, partition_source: false)
      total    = texts.sum(&:length)
      duration = [source.finish - source.start, 0].max
      cursor   = source.start

      texts.map.with_index do |text, index|
        span   = total.zero? ? 0 : duration * text.length.to_f / total
        finish = index == texts.length - 1 ? source.finish : cursor + span
        entry  = Entry.new(
          start:        cursor,
          finish:       finish,
          text:         text,
          words:        [],
          speaker_id:   source.speaker_id,
          cue_id:       source.cue_id,
          source_text:  partition_source ? text : source.source_text,
          source_words: source.source_words.map(&:deep_copy),
          metadata:     self.class.send(:mutable_copy, source.metadata)
        )
        cursor = finish
        entry
      end
    end

    def split_items(items, max_chars, &item_text)
      min_next_size = (max_chars * 0.35).to_i
      buckets       = []
      buffer        = []

      items.each_with_index do |item, index|
        sample = join_items(buffer + [item], item_text)
        if sample.length > max_chars && buffer.any?
          next_text = join_items(items[index..] || [], item_text)
          if next_text.length < min_next_size && buffer.size > 1
            split_index = find_balanced_split(buffer, max_chars, min_next_size, next_text.length, &item_text)
            if split_index && split_index < buffer.size - 1
              buckets << buffer[0..split_index]
              buffer = buffer[(split_index + 1)..] + [item]
            else
              buckets << buffer
              buffer = [item]
            end
          else
            buckets << buffer
            buffer = [item]
          end
        else
          buffer << item
        end
      end
      buckets << buffer if buffer.any?
      buckets
    end

    def find_balanced_split(buffer, max_chars, min_next_size, next_remaining, &item_text)
      return if buffer.size <= 1

      best_index = nil
      best_score = Float::INFINITY
      (0..buffer.size - 2).each do |index|
        first_text = join_items(buffer[0..index], item_text)
        next_text  = join_items(buffer[(index + 1)..], item_text)
        next_total = next_text.length + next_remaining
        next if first_text.length > max_chars || next_total < min_next_size

        score = (max_chars - first_text.length).abs + (min_next_size - next_total).abs
        if score < best_score
          best_score = score
          best_index = index
        end
      end
      best_index
    end

    def join_items(items, item_text)
      items.map { |item| item_text.call(item) }.join(' ').strip
    end

    def translate_texts(texts, from:, to:, translator:, batch_size:)
      service    = translator || ::Translator
      batch_size ||= defined?(::Translator::BATCH_SIZE) ? ::Translator::BATCH_SIZE : 50
      texts.each_slice(batch_size).flat_map do |slice|
        Array(service.translate(slice, from: from, to: to))
      end
    end

    class Entry
      UNSPECIFIED = Object.new.freeze

      attr_reader :start, :finish, :text, :words, :speaker_id, :cue_id, :source_text, :source_words, :metadata

      def self.from_whisper(data)
        data  = Subtitle.send(:json_object, data, 'segment')
        words = Subtitle.send(:optional_array, data['words'], 'words').map { |word| Word.from_whisper(word) }

        new(
          start:      data.fetch('start'),
          finish:     data.fetch('end'),
          text:       data['text'],
          words:      words,
          speaker_id: data['speaker_id'],
          cue_id:     data['cue_id'],
          metadata:   Subtitle.send(:metadata_from, data, %w[start end text words speaker_id cue_id])
        )
      end

      def self.from_transcribe_cpp(data)
        data  = Subtitle.send(:json_object, data, 'segment')
        words = Subtitle.send(:optional_array, data['words'], 'words').map { |word| Word.from_transcribe_cpp(word) }

        new(
          start:      milliseconds(data.fetch('t0_ms'), 't0_ms'),
          finish:     milliseconds(data.fetch('t1_ms'), 't1_ms'),
          text:       data['text'],
          words:      words,
          speaker_id: data['speaker_id'],
          cue_id:     data['cue_id'],
          metadata:   Subtitle.send(:metadata_from, data, %w[t0_ms t1_ms text words speaker_id cue_id])
        )
      end

      def initialize(start:, finish:, text: nil, words: nil, speaker_id: nil, cue_id: nil,
        source_text: UNSPECIFIED, source_words: UNSPECIFIED, metadata: {})
        @start  = Subtitle.send(:number, start, 'start')
        @finish = Subtitle.send(:number, finish, 'finish')
        validate_timing!(@start, @finish)

        @text       = Subtitle.send(:optional_text, text, 'text')
        @words      = Subtitle.send(:typed_array, words || [], Word, 'words')
        @speaker_id = speaker_id
        @cue_id     = cue_id
        @source_text  = source_text.equal?(UNSPECIFIED) ? @text : Subtitle.send(:optional_text, source_text, 'source_text')
        source_words = @words.map(&:deep_copy) if source_words.equal?(UNSPECIFIED)
        @source_words = Subtitle.send(:typed_array, source_words || [], Word, 'source_words')
        @metadata     = Subtitle.send(:immutable_hash, metadata, 'metadata')
      end

      def replace_text!(text)
        @text = Subtitle.send(:optional_text, text, 'text')
        self
      end

      def replace_words!(words)
        @words = Subtitle.send(:typed_array, words || [], Word, 'words')
        self
      end

      def replace_metadata!(metadata)
        @metadata = Subtitle.send(:immutable_hash, metadata, 'metadata')
        self
      end

      def replace_source!(text:, words:)
        @source_text  = Subtitle.send(:optional_text, text, 'source_text')
        @source_words = Subtitle.send(:typed_array, words || [], Word, 'source_words')
        self
      end

      def rebuild_text_from_words!
        @text = @words.map { |word| word.text.strip }.reject(&:empty?).join(' ').freeze
        self
      end

      def replace_timing!(start:, finish:)
        new_start  = Subtitle.send(:number, start, 'start')
        new_finish = Subtitle.send(:number, finish, 'finish')
        validate_timing!(new_start, new_finish)
        @start  = new_start
        @finish = new_finish
        self
      end

      def retime!(start:, finish:)
        new_start  = Subtitle.send(:number, start, 'start')
        new_finish = Subtitle.send(:number, finish, 'finish')
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
        factor = Subtitle.send(:number, factor, 'factor')
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
        tokens = Subtitle.send(:typed_array, tokens, String, 'tokens')
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
        @metadata     = Subtitle.send(:immutable_hash, Subtitle.send(:mutable_copy, @metadata).merge(
          Subtitle.send(:mutable_copy, other.metadata)
        ), 'metadata')
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
          metadata:     Subtitle.send(:mutable_copy, @metadata)
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

      private

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
        @text   = Subtitle.send(:string, text, 'text')
        @start  = Subtitle.send(:number, start, 'start')
        @finish = Subtitle.send(:number, finish, 'finish')
        raise ArgumentError, 'finish must not precede start' if @finish < @start

        @confidence = confidence.nil? ? nil : Subtitle.send(:number, confidence, 'confidence')
        @metadata   = Subtitle.send(:immutable_hash, metadata, 'metadata')
      end

      def replace_text!(text)
        @text = Subtitle.send(:string, text, 'text')
        self
      end

      def replace_timing!(start:, finish:)
        retime!(start: start, finish: finish)
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
          confidence_keys = CONFIDENCE_KEYS.select { |key| data.key?(key) }
          confidence_keys = ['confidence'] if confidence_keys.empty? && !@confidence.nil?
          confidence_keys.each { |key| data[key] = @confidence }
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

      def parse_cues(input, format:)
        raise TypeError, "#{format} must be a String" unless input.is_a?(String)

        newline        = input.include?("\r\n") ? "\r\n" : "\n"
        normalized     = input.gsub(/\r\n?|\r/, "\n")
        validate_cue_document!(normalized, format)
        final_newlines = normalized[/\n*\z/].to_s.length
        blocks         = normalized.split(/\n\n+/)
        entries        = blocks.filter_map.with_index do |block, block_index|
          cue_from_block(block, block_index, format)
        end
        metadata = {
          'source_format'  => format.to_s,
          'line_ending'    => newline,
          'final_newlines' => final_newlines,
        }
        if format == :srt
          source_blocks = input.split(/\r?\n\r?\n+/)
          metadata.merge!(
            'source_blocks'      => source_blocks,
            'cue_block_indices'  => entries.map { |entry| entry.metadata.fetch('block_index') },
          )
        end
        new(
          text: entries.map(&:text).join(' '),
          entries: entries,
          metadata: metadata
        )
      end

      def cue_from_block(block, block_index, format)
        lines        = block.lines(chomp: true)
        timing_index = lines.index { |line| line.include?('-->') }
        return unless timing_index

        timestamps = lines.fetch(timing_index).scan(Subtitler::TIMESTAMP_VALUE)
        start_time = Subtitler.parse_timestamp(timestamps[0])
        finish_time = Subtitler.parse_timestamp(timestamps[1])
        return unless start_time && finish_time

        content_lines = lines[(timing_index + 1)..] || []
        raw_text      = content_lines.join("\n")
        text          = semantic_text(raw_text)
        return if text.empty?

        cue_id = lines[0...timing_index].reverse.find { |line| !line.strip.empty? }
        cue_id = block_index if format == :vtt && cue_id.nil?
        words  = inline_timed_words(raw_text, start_time, finish_time, cue_id)
        Entry.new(
          start:  start_time,
          finish: finish_time,
          text:   text,
          words:  words,
          cue_id: cue_id,
          metadata: {
            'content_lines' => content_lines,
            'ass_text'      => CGI.unescapeHTML(raw_text).gsub(Subtitler::INLINE_TIMESTAMP, ''),
            'source_start'  => start_time,
            'source_finish' => finish_time,
            'source_text'   => text,
            'timing_line'   => lines.fetch(timing_index),
            'prefix_lines'  => lines[0...timing_index],
            'block_index'   => block_index,
          }
        )
      end

      def inline_timed_words(text, cue_start, cue_finish, cue_id)
        matches = text.to_enum(:scan, /<([^>]*)>/).map { Regexp.last_match }
        malformed = matches.any? do |match|
          match[1].match?(/\A\d{1,2}:\d{2}/) && Subtitler.parse_timestamp(match[1]).nil?
        end
        timed = text.to_enum(:scan, Subtitler::INLINE_TIMESTAMP).filter_map do
          match = Regexp.last_match
          time  = Subtitler.parse_timestamp(match[1])
          [match, time] if time
        end
        return [] if malformed || timed.empty?

        times = timed.map(&:last)
        return [] unless times.all? { |time| time >= cue_start && time <= cue_finish }
        return [] unless times.each_cons(2).all? { |left, right| right > left }

        chunks = []
        cursor = 0
        timed.each do |match, _time|
          chunks << text[cursor...match.begin(0)]
          cursor = match.end(0)
        end
        chunks << text[cursor..]

        boundaries = [cue_start, *times, cue_finish]
        chunks.flat_map.with_index do |chunk, index|
          tokens = semantic_text(chunk).split
          next [] if tokens.empty?

          start_time  = boundaries.fetch(index)
          finish_time = boundaries.fetch(index + 1)
          return [] unless finish_time > start_time

          duration = finish_time - start_time
          tokens.map.with_index do |token, token_index|
            token_start  = start_time + duration * token_index / tokens.size
            token_finish = token_index == tokens.size - 1 ? finish_time : start_time + duration * (token_index + 1) / tokens.size
            Word.new(
              text: token,
              start: token_start,
              finish: token_finish,
              metadata: {'cue_id' => cue_id, 'marker' => index.positive? && token_index.zero?, 'marker_group' => index}
            )
          end
        end
      end

      def validate_cue_document!(input, format)
        if format == :vtt
          header = input.each_line.first&.strip
          raise ArgumentError, 'invalid WEBVTT header' unless header&.match?(/\A\uFEFF?WEBVTT(?:[ \t].*)?\z/)
        end

        timing_lines = input.each_line.select do |line|
          if format == :vtt
            line.include?('-->')
          else
            line.match?(/\A\s*#{Subtitler::TIMESTAMP_VALUE}\s+-->/)
          end
        end
        timing_lines.each do |line|
          label = format == :vtt ? 'WEBVTT' : 'SRT'
          raise ArgumentError, "invalid #{label} cue timing" unless line.match?(Subtitler::CUE_TIMING)

          start_text, finish_text = line.scan(Subtitler::TIMESTAMP_VALUE).first(2)
          start_time  = Subtitler.parse_timestamp(start_text)
          finish_time = Subtitler.parse_timestamp(finish_text)
          unless start_time && finish_time && finish_time > start_time
            raise ArgumentError, "invalid #{label} cue range"
          end
        end
      end

      def semantic_text(text)
        plain = text.to_s.gsub(/<br\s*\/?\s*>/i, ' ').gsub(/<[^>]*>/, '')
        Nokogiri::HTML5.fragment(plain).text.split.join(' ')
      end

      def time_value(value, field)
        return number(value, field) if value.is_a?(Numeric)

        parsed = Subtitler.parse_timestamp(value)
        raise ArgumentError, "invalid #{field} timestamp" unless parsed

        parsed
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

      def optional_array(value, field)
        return [] if value.nil?
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

      def optional_text(value, field)
        value.nil? ? ''.freeze : string(value, field)
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
