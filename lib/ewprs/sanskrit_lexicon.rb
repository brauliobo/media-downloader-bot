require 'nokogiri'

require_relative 'translation_markup'

module Ewprs
  class SanskritLexicon
    include TranslationMarkup

    DEFAULT_TERMS = [
      'Yoga Darshana',
      'Bhagavat Dharma',
      'sumum bonum',
      'summum bonum',
      *%w[
        Brahma Shiva Shakti Prakrti Purusa Purusottama Japa Khotta Saptasindhu Shaorasenii
        Demi-Shaorasenii Ardha Vaedika agni ajja ajjii arya bauls devatva dharma kula Tantra yoga
        sadhana samadhi mantra kiirtana rasa tadsthiti tattva vipras vrtti pravrtti nivrtti samskara
        amrta caetanya hasant madhyama mudra nrtya pratibha sarjana sargam srjanii
        Shivatattva utsarjana vilambita visarjana
        pra karoti iti
      ]
    ].freeze
    TRANSLATABLE_TERMS = %w[linseed].to_h { |term| [term, true] }.freeze

    attr_reader :gloss_pattern, :inline_gloss_pattern, :parenthetical_gloss_pattern

    def initialize(root)
      path = File.join(root, 'HTML/Info/MasterGlossary.html')
      raw = File.binread(path)
      html = raw.dup.force_encoding(Encoding::UTF_8)
      html = raw.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8) unless html.valid_encoding?
      document = Nokogiri::HTML5.parse(html)
      @terms = document.css('b').flat_map { |node| variants(node.text) }
      @terms.concat(DEFAULT_TERMS)
      @terms = @terms.map(&:strip).reject do |term|
        term.length < 3 || TRANSLATABLE_TERMS.key?(term.downcase)
      end.uniq.sort_by { |term| -term.length }
      @term_values = @terms.to_h { |term| [term.downcase, true] }
      patterns = @terms.map do |term|
        pattern = term.split(/\s+/).map { |word| Regexp.escape(word) }.join('\\s+')
        term.match?(/\A[A-Z][a-z]{0,2}\z/) ? "(?-i:#{pattern})" : pattern
      end
      @pattern = /(?<![A-Za-z])(?:#{patterns.join('|')})(?![A-Za-z])/i
      @inline_pattern = %r{<(?<tag>i|em)\b[^>]*>\s*#{@pattern}\s*</\k<tag>\s*>}i
      @inline_gloss_pattern = %r{
        (?<term>#{@inline_pattern})(?<spacing>\s*)
        (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
      }ix
      @gloss_pattern = %r{
        (?<term>(?:#{MARKED_WORD}|#{ASCII_TRANSLITERATED_WORD}|#{@pattern}))(?<spacing>\s*)
        (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
        (?<suffix>\s+(?<![A-Za-z])(?-i:[A-Z])[A-Za-z'’-]*(?![A-Za-z]|&\#x(?:301|32D);))?
      }ix
      @parenthetical_gloss_pattern = %r{
        (?<term>#{@pattern})(?<spacing>\s*)
        (?<opening>\()(?<gloss>[^()\r\n]+)(?<closing>\))
      }ix
    end

    def mask(value, tokens)
      value.gsub(@pattern) do |match|
        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = match
        marker
      end
    end

    def mask_inline(value, tokens)
      value.gsub(@inline_pattern) do |match|
        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = match
        marker
      end
    end

    def term?(value)
      @term_values.key?(value.to_s.strip.downcase)
    end

    private

    def variants(value)
      values = [value, *value.split(/\s+(?:or|and)\s+|[,;]/i)]
      values.flat_map do |term|
        clean = term.gsub(/\b[fm]\.$/i, '').strip
        ascii = clean.unicode_normalize(:nfd).gsub(/\p{M}/, '')
        [clean, ascii]
      end
    end
  end
end
