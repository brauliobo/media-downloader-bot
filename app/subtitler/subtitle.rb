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

    include Rendering
    include Merging
    include Splitting
    include Translation

    attr_reader :language, :text, :entries, :metadata

    def self.from_whisper_verbose_json(input)
      data = Values.parse_json_object(input)
      metadata = Values.metadata_from(data, %w[language text segments]).merge('timing_source' => 'whisper')

      new(
        language: data['language'],
        text:     data['text'],
        entries:  data.fetch('segments').map { |entry| Entry.from_whisper(entry) },
        metadata: metadata
      )
    end

    def self.from_transcribe_cpp_json(input)
      data = Values.parse_json_object(input)

      new(
        language: data['language'],
        text:     data['text'],
        entries:  data.fetch('segments').map { |entry| Entry.from_transcribe_cpp(entry) },
        metadata: Values.metadata_from(data, %w[language text segments])
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
      raw = Values.text(text).scan(TOKEN)
      raw.each_with_object([]) do |token, tokens|
        if token.match?(/\A[^\p{L}\d\s]+\z/) && tokens.any?
          tokens[-1] = "#{tokens.last}#{token}"
        else
          tokens << token
        end
      end
    end

    def self.clean_translation(text)
      Values.text(text).strip.sub(TRANSLATION_PREFIX, '').strip
    end

    def initialize(language: nil, text: nil, entries: [], metadata: {})
      @language = Values.string_or_nil(language)
      @text     = Values.text(text)
      @entries  = Values.list(entries)
      @metadata = Values.immutable_copy(metadata)
    end

    def replace_language!(language)
      @language = Values.string_or_nil(language)
      self
    end

    def replace_text!(text)
      @text = Values.text(text)
      self
    end

    def replace_entries!(entries)
      @entries = Values.list(entries)
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
      factor = Values.number(factor, 'factor')
      raise ArgumentError, 'factor must not be negative' if factor.negative?

      @entries.each { |entry| entry.scale_timing!(factor) }
      self
    end

    def assign_speaker!(speaker_id)
      @entries.each { |entry| entry.assign_speaker!(speaker_id) }
      self
    end

    def normalize_entries!(max_chars: MAX_ENTRY_CHARS, gap_threshold: 1.0, respect_speaker: true)
      split_long_entries!(max_chars: max_chars)
      merge_adjacent!(max_chars: max_chars, gap_threshold: gap_threshold, respect_speaker: respect_speaker)
    end

    def slice(from:, to:, rebase: true)
      range_start  = Values.time_value(from, 'from')
      range_finish = Values.time_value(to, 'to')
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
        metadata: Values.mutable_copy(@metadata).merge('numbered_cues' => true)
      )
    end

    def deep_copy
      self.class.new(
        language: @language,
        text:     @text,
        entries:  @entries.map(&:deep_copy),
        metadata: Values.mutable_copy(@metadata)
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
        metadata:   derived_metadata(entry.metadata)
      )
    end
  end
end
