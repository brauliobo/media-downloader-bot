require 'json'
require 'cgi'
require 'nokogiri'
require 'securerandom'

class Subtitler
  class Subtitle
    MAX_ENTRY_CHARS    = 84
    TRANSLATION_PREFIX = /\A(?:translation|translated(?:\s+text)?|answer|response)\s*:\s*/i
    NOISE_DOTS_LINE    = /\A\s*\d(?:\s*\.\s*\d){3,}\.??\s*\z/.freeze
    FORMAT_TEXT_METADATA_KEYS = %w[ass_text source_signature].freeze
    RAW_CUE_METADATA_KEYS      = %w[
      ass_text source_signature content_lines timing_line prefix_lines
      source_start source_finish source_text block_index
    ].freeze

    attr_reader :language, :text, :entries, :metadata

    # The same contract is asserted wherever a subtitle crosses a module boundary; the message
    # names the argument so the caller can tell which one it was.
    def self.assert!(value, name)
      raise TypeError, "#{name} must be a Subtitler::Subtitle" unless value.is_a?(self)

      value
    end

    def self.from_whisper_verbose_json(input)
      data = Types.parse_json_object(input)
      metadata = Types.metadata_from(data, %w[language text segments]).merge('timing_source' => 'whisper')

      new(
        language: data['language'],
        text:     data['text'],
        entries:  Types.fetch_array(data, 'segments').map { |entry| Entry.from_whisper(entry) },
        metadata: metadata
      )
    end

    def self.from_transcribe_cpp_json(input)
      data = Types.parse_json_object(input)

      new(
        language: data['language'],
        text:     data['text'],
        entries:  Types.fetch_array(data, 'segments').map { |entry| Entry.from_transcribe_cpp(entry) },
        metadata: Types.metadata_from(data, %w[language text segments])
      )
    end

    def self.from_vtt(vtt)
      Cues.parse(vtt, format: :vtt)
    end

    def self.from_srt(srt)
      Cues.parse(srt, format: :srt)
    end

    # Tokens are the words as written: the text is rejoined with spaces, so splitting inside a word
    # ("7.000", "414ª", "COVID-19", "www.site.com") would put spaces where there were none. Only
    # the ideographic clause marks split, as languages written without spaces have no other boundary.
    CLAUSE_MARKS = '、，。！？；：'.freeze
    TOKEN        = /[^\s#{CLAUSE_MARKS}]*[#{CLAUSE_MARKS}]+|[^\s#{CLAUSE_MARKS}]+/

    def self.tokenize(text)
      raw = Types.optional_text(text, 'text').scan(TOKEN)
      raw.each_with_object([]) do |token, tokens|
        if token.match?(/\A[^\p{L}\d\s]+\z/) && tokens.any?
          tokens[-1] = "#{tokens.last}#{token}"
        else
          tokens << token
        end
      end
    end

    def self.clean_translation(text)
      Types.optional_text(text, 'translation').strip.sub(TRANSLATION_PREFIX, '').strip
    end

    def initialize(language: nil, text: nil, entries: [], metadata: {})
      @language = Types.optional_string(language, 'language')
      @text     = Types.optional_text(text, 'text')
      @entries  = Types.typed_array(entries, Entry, 'entries')
      @metadata = Types.immutable_hash(metadata, 'metadata')
    end

    def replace_language!(language)
      @language = Types.optional_string(language, 'language')
      self
    end

    def replace_text!(text)
      @text = Types.optional_text(text, 'text')
      self
    end

    def replace_entries!(entries)
      @entries = Types.typed_array(entries, Entry, 'entries')
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
      factor = Types.number(factor, 'factor')
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
      sentences = @entries.chunk_while do |left, right|
        representation_and_boundary(left) == representation_and_boundary(right)
      end.flat_map do |run|
        if run.first.words.any?
          Sentences.from_entries(run.map(&:deep_copy)).each do |entry|
            entry.assign_speaker!(run.first.speaker_id)
            entry.assign_cue!(run.first.cue_id)
            entry.replace_metadata!(derived_metadata(run.first.metadata))
          end
        else
          run.flat_map { |entry| text_sentence_entries(entry) }
        end
      end.select { |entry| entry.finish > entry.start }

      WhisperTimings.normalize!(sentences, duration: @metadata['duration']) if @metadata['timing_source'] == 'whisper'
      sentences
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

    def translate_srt!(from: nil, to:, translator: nil, batch_size: nil)
      raise ArgumentError, 'subtitle source must be SRT' unless @metadata['source_format'] == 'srt'

      lines = @entries.flat_map { |entry| entry.metadata.fetch('content_lines') }
      masked, replacements, marker_pattern = protect_srt_timestamps(lines)
      translated_lines = translate_texts(
        masked, from: from, to: to, translator: translator, batch_size: batch_size
      )
      unless translated_lines.length == lines.length
        raise "SRT translation result count mismatch: expected #{lines.length}, got #{translated_lines.length}"
      end

      translated_lines = translated_lines.zip(replacements).map do |text, line_replacements|
        expected = line_replacements.map(&:first)
        actual   = text.to_s.scan(marker_pattern)
        unless actual == expected
          raise "SRT translation corrupted inline timestamps: expected #{expected.join(', ')}"
        end

        values = line_replacements.to_h
        text.to_s.gsub(marker_pattern) { |marker| values.fetch(marker) }
      end

      source_blocks = Types.mutable_copy(@metadata.fetch('source_blocks'))
      cursor        = 0
      @entries.each do |entry|
        content_lines = translated_lines.slice(cursor, entry.metadata.fetch('content_lines').length)
        cursor += content_lines.length
        translated_text = Cues.semantic_text(content_lines.join("\n"))
        words = Cues.inline_timed_words(content_lines.join("\n"), entry.start, entry.finish, entry.cue_id)
        entry.replace_text!(translated_text)
          .replace_words!(words)
          .replace_source!(text: translated_text, words: words.map(&:deep_copy))
        entry.replace_metadata!(Types.mutable_copy(entry.metadata).merge(
          'content_lines' => content_lines,
          'ass_text'      => CGI.unescapeHTML(content_lines.join("\n")).gsub(Subtitler::Timestamps::INLINE_TIMESTAMP, ''),
          'source_text'   => translated_text
        ))
        block_index = entry.metadata.fetch('block_index')
        block_end   = source_blocks.fetch(block_index)[/(?:\r?\n)+\z/].to_s
        source_blocks[block_index] = original_srt_lines(entry).join(@metadata.fetch('line_ending')) + block_end
      end
      @metadata = Types.immutable_hash(
        Types.mutable_copy(@metadata).merge('source_blocks' => source_blocks),
        'metadata'
      )
      replace_language!(to)
      rebuild_text_from_entries!
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
      @metadata = Types.immutable_hash(
        Types.mutable_copy(@metadata).merge('rejected_block_indices' => rejected_blocks),
        'metadata'
      )
      rebuild_text_from_entries!
    end

    def slice(from:, to:, rebase: true)
      range_start  = Types.time_value(from, 'from')
      range_finish = Types.time_value(to, 'to')
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
        metadata: Types.mutable_copy(@metadata).merge('numbered_cues' => true)
      )
    end

    def to_vtt(word_tags: true)
      render_cues(format: :vtt, word_tags: word_tags)
    end

    def to_srt(word_tags: true)
      render_cues(format: :srt, word_tags: word_tags)
    end

    def to_ass(portrait: false, mode: :instagram, preset: 'default')

      Subtitler::Ass.document_for(self, portrait: portrait, mode: mode, preset: preset).to_s
    end

    def deep_copy
      self.class.new(
        language: @language,
        text:     @text,
        entries:  @entries.map(&:deep_copy),
        metadata: Types.mutable_copy(@metadata)
      )
    end

    private

    def protect_srt_timestamps(lines)
      prefix = nil
      loop do
        candidate = "__SRT_TS_#{SecureRandom.hex(8)}_"
        unless lines.any? { |line| line.include?(candidate) }
          prefix = candidate
          break
        end
      end
      marker_pattern = /#{Regexp.escape(prefix)}\d+__/
      index = 0
      replacements = []
      masked = lines.map do |text|
        line_replacements = []
        protected_text = text.gsub(Subtitler::Timestamps::INLINE_TIMESTAMP) do |timestamp|
          marker = "#{prefix}#{index}__"
          index += 1
          line_replacements << [marker, timestamp]
          marker
        end
        replacements << line_replacements
        protected_text
      end
      [masked, replacements, marker_pattern]
    end

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
        metadata:   derived_metadata(entry.metadata)
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
        lines.concat(cue_prefix_lines(entry, index, format))
        lines << cue_timing_line(entry, start_time, finish_time, decimal, format)
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

    def cue_prefix_lines(entry, index, format)
      if format == :vtt
        return entry.metadata.fetch('prefix_lines') if entry.metadata.key?('prefix_lines')
        return [(index + 1).to_s] if @metadata['numbered_cues']

        return []
      end

      [cue_identifier(entry, index, format)].compact
    end

    def cue_identifier(entry, index, format)
      return (index + 1).to_s if format == :srt && entry.cue_id.nil?
      return entry.cue_id.to_s if format == :srt
      return unless @metadata['numbered_cues']

      (index + 1).to_s
    end

    def cue_timing_line(entry, start_time, finish_time, decimal, format)
      if format == :vtt && original_vtt_entry?(entry)
        return entry.metadata.fetch('timing_line')
      end

      settings = format == :vtt && @metadata['source_format'] == 'vtt' ? vtt_timing_settings(entry) : ''
      "#{Subtitler.format_timestamp(start_time, decimal: decimal)} --> #{Subtitler.format_timestamp(finish_time, decimal: decimal)}#{settings}"
    end

    def render_entry_text(entry, start_time, finish_time, decimal, word_tags, format)
      if format == :vtt && original_vtt_entry?(entry)
        content_lines = entry.metadata.fetch('content_lines')
        content_lines = content_lines.map { |line| line.gsub(Subtitler::Timestamps::INLINE_TIMESTAMP, '') } unless word_tags
        return content_lines.join("\n")
      end
      if format == :vtt && @metadata['source_format'] == 'srt' && original_srt_entry?(entry)
        return entry.metadata.fetch('content_lines').join("\n").gsub(Subtitler::Timestamps::INLINE_TIMESTAMP) do |timestamp|
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

    def original_vtt_entry?(entry)
      @metadata['source_format'] == 'vtt' &&
        entry.metadata['source_signature'] == Cues.source_signature(
          start: entry.start, finish: entry.finish, text: entry.text,
          cue_id: entry.cue_id, words: entry.words)
    end

    def vtt_timing_settings(entry)
      timing_line = entry.metadata['timing_line']
      return '' unless timing_line

      match = timing_line.match(/\A\s*#{Subtitler::Timestamps::TIMESTAMP_VALUE}\s+-->\s+#{Subtitler::Timestamps::TIMESTAMP_VALUE}(.*)\z/)
      match ? match[1] : ''
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

    def derived_entry_copy(entry)
      entry.deep_copy.replace_metadata!(derived_metadata(entry.metadata))
    end

    def derived_metadata(metadata)
      Types.mutable_copy(metadata).reject do |key, _|
        RAW_CUE_METADATA_KEYS.include?(key.to_s)
      end
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
      parts = Text::SentenceSplitter.sentences(entry.text.strip)
      return [] if parts.empty?
      return [derived_entry_copy(entry)] if parts.size == 1

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
        metadata:     derived_metadata(source.metadata)
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
          metadata:     derived_metadata(source.metadata)
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
  end
end
