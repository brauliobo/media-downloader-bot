require 'cgi'
require 'digest'
require 'fileutils'
require 'json'
require 'nokogiri'
require 'open3'
require 'pathname'
require 'time'

require_relative '../jsonl_store'
require_relative 'sentence_splitter'
require_relative 'translator'
require_relative 'translation_validator'

module Ewprs
  class TranslationBatch
    CONTENT_CLASSES = %w[
      Para_Major_Heading Para_Minor_Heading Para_Indent plain Para_Sloka
      Para_Translation_Eds Para_Citation Para_Quote Para_Footnote center
    ].freeze
    PROMPT_VERSION = 10
    BATCH_SIZE     = 50
    MAX_UNIT_CHARS = 800
    MAX_INLINE_EDITORIAL_CHARS = 80
    TOKEN_RETRIES  = 2
    WINDOWS_CONTROLS = {
      "\u0085" => '...', "\u0091" => "'", "\u0092" => "'",
      "\u0093" => '"', "\u0094" => '"', "\u0096" => '-', "\u0097" => '--'
    }.freeze

    class ProtectedTokenError < StandardError; end

    Entry = Struct.new(:kind, :path, keyword_init: true) do
      def slug = File.basename(path, File.extname(path))
    end

    Document = Struct.new(:entry, :template, :encoding, :mode, :raw, keyword_init: true)
    Unit     = Struct.new(:key, :source, :prepared, :tokens, :leading, :trailing, keyword_init: true)

    PROTECTED_ELEMENT = %r{
      <(?<tag>script|style)\b[^>]*>.*?</\k<tag>\s*>|
      <p\b(?=[^>]*\bclass\s*=\s*["']?Para_Sloka\b)[^>]*>.*?</p\s*>|
      <span\b(?=[^>]*\bclass\s*=\s*["']?Bengali\b)[^>]*>.*?</span\s*>
    }mix
    BLOCK_CONTENT = /(<!--\s*block\b[^>]*\btype=(?:paragraph|title)\b[^>]*-->)(.*?)(<!--\s*\/block\s*-->)/mi
    GROUPED_PARAGRAPH = %r{
      (<p\b(?=[^>]*\bclass\s*=\s*["']?(?:Para_Notes|Para_Footnote)\b)[^>]*>)
      (.*?)
      (</p\s*>)
    }mix
    GROUPED_DIV = %r{
      (<div\b(?=[^>]*\bclass\s*=\s*["']?(?:discourse_title|book_title|book_contents|book_chapter_title)\b)[^>]*>)
      (.*?)
      (</div\s*>)
    }mix
    EMPTY_INLINE_ELEMENT = Regexp.union(
      %w[i em b strong span u sup sub].map { |tag| /<#{tag}\b[^>]*>\s*<\/#{tag}\s*>/i }
    )
    FOOTNOTE          = /<!--\s*fn\s*-->.*?<!--\s*\/fn\s*-->/mi
    EDITORIAL_CONTENT = /\[\[?[^\[\]\r\n]+\]\]?/
    HYPHENATED_EDITORIAL = /(?<prefix>\b[A-Za-z][A-Za-z'’-]*)-(?<editorial>#{EDITORIAL_CONTENT})/
    ATTACHED_EDITORIAL = /(?<prefix>\b[A-Za-z][A-Za-z'’-]*)(?<editorial>#{EDITORIAL_CONTENT})/
    STRUCTURAL_MARKUP = %r{#{FOOTNOTE}|#{EMPTY_INLINE_ELEMENT}|<br\s*/?>|</?(?:table|thead|tbody|tfoot|tr|td|th|ul|ol|li)\b[^>]*>}i
    TEXT_NODE        = /(?<=>)([^<]+)(?=<)/m
    MARKED_WORD      = /(?<![A-Za-z])(?:[A-Za-z][A-Za-z'’-]*)(?:(?:&#x(?:301|32D);)[A-Za-z'’-]*)+(?![A-Za-z])/i
    ASCII_TRANSLITERATED_WORD = /(?<![A-Za-z])[A-Za-z]*(?:aa|ii|uu)[A-Za-z]*(?![A-Za-z])/i
    PROPER_NOUN_GLOSS = %r{
      (?<prefix>\b(?i:at|from|in|near|of)\s+)
      (?<term>(?<![A-Za-z])[A-Z][a-z][A-Za-z'’-]*(?![A-Za-z]))(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }x
    MARKED_INLINE    = %r{<(?<tag>i|em)\b[^>]*>\s*#{MARKED_WORD}[;,]?\s*</\k<tag>\s*>}i
    FOREIGN_INLINE   = %r{<(?<tag>i|em)\b[^>]*>(?<content>.*?)</\k<tag>\s*>}mi
    MARKED_INLINE_GLOSS = %r{
      (?<term><(?<tag>i|em)\b[^>]*>(?=[^<]*[A-Za-z])[^<]*</\k<tag>>)(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }ix
    MARKED_PHRASE_GLOSS = %r{
      (?<term>#{MARKED_WORD}(?:\s+(?:#{MARKED_WORD}|[A-Za-z][A-Za-z'’-]*)){1,6})(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }ix
    CONSONANT_TERM_GLOSS = %r{
      (?<term>(?<![A-Za-z])(?=[a-z]{2,4}(?![A-Za-z]))[b-df-hj-np-tv-z]+)(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }x
    DEFINED_TERM_GLOSS = %r{
      (?<term>(?<=\bmeans\s)[a-z][a-z'’-]*)(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }ix
    HYPHENATED_TERM_GLOSS = %r{
      (?<term>(?<![A-Za-z])[A-Za-z][A-Za-z'’]*(?:-[A-Za-z][A-Za-z'’]*)+)(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }x
    QUOTED_GLOSS = %r{
      (?<term>&(?:rdquo|quot);)(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }ix
    NAMED_MARKED_GROUP = %r{
      (?<prefix>\b(?i:of)\s+)
      (?<name>(?<![A-Za-z])[A-Z][A-Za-z'’-]*(?![A-Za-z]))\s+(?<group>#{MARKED_WORD})
    }x
    GLOSS_TERM = /(?:#{MARKED_WORD}|(?<![A-Za-z])[A-Za-z][A-Za-z'’-]*(?![A-Za-z]))/
    COORDINATED_PARENTHETICAL_GLOSSES = %r{
      (?<first_term>#{GLOSS_TERM})(?<first_spacing>\s*)\((?<first_gloss>[^()\r\n]+)\)
      (?<coordination>\s+and\s+)
      (?<second_term>#{GLOSS_TERM})(?<second_spacing>\s*)\((?<second_gloss>[^()\r\n]+)\)
    }ix
    COORDINATED_BRACKETED_GLOSSES = %r{
      (?<first_term>#{MARKED_WORD})(?<first_spacing>\s*)
      (?<first_opening>\[\[?)(?<first_gloss>[^\[\]\r\n]+)(?<first_closing>\]\]?)
      (?<coordination>\s+(?:and|or)\s+(?:an?\s+)?)
      (?<second_term>#{GLOSS_TERM})(?<second_spacing>\s*)
      (?<second_opening>\[\[?)(?<second_gloss>[^\[\]\r\n]+)(?<second_closing>\]\]?)
    }ix
    COORDINATED_WITH_GLOSSES = %r{
      (?<prefix>\bwith\s+)(?<first_term>#{GLOSS_TERM})(?<first_spacing>\s*)
      (?<first_opening>\[\[?)(?<first_gloss>[^\[\]\r\n]+)(?<first_closing>\]\]?)
      (?<coordination>\s+nor\s+with\s+)
      (?<second_term>#{GLOSS_TERM})(?<second_spacing>\s*)
      (?<second_opening>\[\[?)(?<second_gloss>[^\[\]\r\n]+)(?<second_closing>\]\]?)
    }ix
    EDITORIAL_BRACKET = /\[\[?|\]\]?/
    EDITORIAL_TAG = %r{<span data-ewprs="[12][12]">|</span>}i
    PAIRED_DELIMITER  = /[()\[\]{}]/
    PARENTHETICAL_CONTENT = /\((?<content>[^()\r\n]+)\)/
    INLINE_ORIGINAL  = %r{
      (?:
        (?<=,\s)
        (?=(?:[A-Za-z]+\s+)?#{MARKED_WORD})[^<>.!?\r\n]+?[.!?]?
        \s+(?=\[(?:&(?:ldquo|quot);|["“]))
      |
        (?<=\b(?-i:And)\s)
        (?=(?:[A-Za-z]+\s+)?#{MARKED_WORD})[^<>.!?\r\n]+?[.!?]?
        \s+(?=\[(?:&(?:ldquo|quot);|["“]|(?=(?-i:[A-Z]))))
      )
    }ix
    BIBLIOGRAPHIC_TITLE = /(?<=\bsee\s)[A-Z][^,.;\r\n]+(?=,\s*\d{4}\b)/
    PARTED_PUBLICATION_TITLE = %r{
      (?<=\bpublication\sin\s)[A-Z][^,.\r\n]+(?=,\s*Part\s+\d+,\s*\d{4}\b)
    }ix
    DATED_PUBLICATION_TITLE = %r{
      (?<=\bpublication\sin\s)[A-Z][^,.\r\n]+(?=,\s*\d{4}\b)
    }ix
    NUMBERED_SERIES_TITLE = %r{
      (?<=\bin\s)[A-Z][A-Za-z'’-]*(?:\s+(?:[a-z]{1,4}|[A-Z][A-Za-z'’-]*)){2,}
      (?=\s+\d+,\s*\d{4}\b)
    }x
    ITALIC_CITATION_TITLE = %r{
      <(?<tag>i|em)\b[^>]*>[^<>]+</\k<tag>\s*>
      (?=\s*,?\s*(?:\d{4}\b|(?:\d+(?:st|nd|rd|th)|[A-Z][a-z]+)\s+edition\b))
    }ix
    ITALIC_EDITION_TITLE = %r{
      (?<=\bEdition\sof\s)<(?<tag>i|em)\b[^>]*>[^<>]+</\k<tag>\s*>
    }ix
    BOOK_TITLE = %r{
      (?<=\bbook\s)[A-Z][A-Za-z'’-]*
      (?:\s+(?:a|an|and|for|from|in|of|on|or|the|to|[A-Z][A-Za-z'’-]*)){2,}
      (?=[.,]|\z)
    }x
    SEE_PARENTHETICAL_TITLE = %r{
      (?<=\bSee\sespecially\s)[A-Z][A-Za-z'’-]*
      (?:\s+(?:a|an|and|for|from|in|of|on|or|the|to|[A-Z][A-Za-z'’-]*)){2,}
      (?=\s+\(\d{4}\))
    }x
    EDITIONED_TITLE = %r{
      (?<=\bin\s)[A-Z][A-Za-z'’-]*
      (?:\s+(?:a|an|and|for|from|in|of|on|or|the|to|[A-Z][A-Za-z'’-]*)){2,}
      (?=,\s*\d+(?:st|nd|rd|th)\s+edition\b)
    }x
    VOLUME_CITATION_TITLE = %r{
      (?<=\bin\s)[A-Z](?:&(?:\#x[\dA-Fa-f]+|\#\d+|[A-Za-z]+);|[^,.;\r\n])+
      (?=\s+(?i:Vol(?:ume)?\.?)\s*\d+\b)
    }x
    PUBLICATION_LIST = /(?<=\bworks\ssuch\sas\s)[^.\r\n]+(?=\.)/i
    MAGAZINE_LIST = /(?<=\bmagazines:\s)[^\r\n]+?(?=\s+and\s+others\b)/i
    QUOTED_PUBLICATION_TITLE = %r{
      (?<prefix>
        \b(?:(?:published|appeared|publication)[^.!?\r\n]{0,120}\bas(?:\s+parts?\s+of)?|titled|entitled)\s
      )
      (?<title>&ldquo;.*?&rdquo;)
    }ix
    QUOTED_LANGUAGE_EXAMPLE = %r{
      (?<prefix>
        \b(?:(?:use|uses|using|word|phrase|sentence|expression|term)\s+|(?:say|says|said)\s*:\s*)
      )
      (?<example>&ldquo;.*?&rdquo;)
    }ix
    UNQUOTED_PUBLICATION_TITLE = %r{
      (?<=\bincluded\sin\s)
      [A-Z][A-Za-z'’-]*(?:\s+(?:[a-z]{1,4}|[A-Z][A-Za-z'’-]*)){2,}
      (?=\s+in\s+which\b)
    }x
    QUOTED_TITLE = /&ldquo;.*?&rdquo;/i
    TITLE_CONNECTORS = %w[a an and for from in of on or the to].freeze
    MARKUP           = /#{FOOTNOTE}|#{MARKED_INLINE}|<!--.*?-->|<[^>]+>/m
    STANDALONE_MARKUP = /\A(?:<!--.*?-->|<[^>]+>)\z/m
    INDIC_SCRIPT     = /[\p{Devanagari}\p{Bengali}]+/
    TECHNICAL_VALUE  = /(?:\bEE\d+(?:\.\d+)?\b|\b[^\s<>]+\.html\b)/i
    PLACEHOLDER      = /__P\d{4}__/
    ADJACENT_PROTECTED_TERMS = /(?<left>__P\d{4}__)(?<spacing>\s+)(?<right>__P\d{4}__)/
    QUANTIFIER       = /(?:one|two|three|four|five|six|seven|eight|nine|ten|\d+)/i
    COORDINATED_PLACEHOLDER = %r{
      (?<first>\b#{QUANTIFIER}\s+[A-Za-z-]+)\s+and\s+
      (?<second>#{QUANTIFIER}\s+[A-Za-z-]+)\s+(?<term>#{PLACEHOLDER})
    }ix
    PROTECTED_MARKER = /⟦P[0-9a-f]+⟧/
    UNIT_MARKER      = /⟦U([0-9a-f]{64})⟧/
    DOCUMENT_MARKER  = /#{PROTECTED_MARKER}|#{UNIT_MARKER}/
    ESCAPED_ENTITY   = /&amp;(?=(?:#\d+|#x[\da-f]+|[a-z][\w]+);)/i

    attr_reader :root, :source_language, :target, :source_ref, :branch, :cache_path, :translator, :stdout,
                :validator

    def initialize(root:, source_language: 'en', target: 'pt', source_ref: '7.5', branch: '7.5-pt', cache: nil,
                   translator: Translator.new, stdout: $stdout)
      @root            = File.expand_path(root)
      @source_language = source_language
      @target          = target
      @source_ref      = source_ref
      @branch          = branch
      @cache_path      = File.expand_path(cache || "tmp/ewprs_translations/#{branch}.jsonl", Dir.pwd)
      @translator      = translator
      @stdout          = stdout
      @lexicon         = SanskritLexicon.new(@root)
      @validator       = TranslationValidator.new(source_language: source_language, target_language: target)
      @units           = {}
      @protected       = 0
    end

    def plan(only: nil)
      documents = prepare_documents(entries(only: only))
      cached = validated_cached_translations
      {
        root:              root,
        source_ref:        source_ref,
        branch:            branch,
        target:            target,
        files:             documents.size,
        classes:           class_inventory(documents.map(&:raw)),
        units:             @units.size,
        cached_units:      cached.size,
        untranslated_units: @units.size - cached.size,
        protected_elements: @protected,
        cache:             cache_path
      }
    end

    def run(only: nil)
      prepare_branch!
      documents = prepare_documents(entries(only: only))
      translations = translate_units
      documents.each_with_index do |document, index|
        rendered = render(document, translations)
        validate_structure!(document.raw, rendered)
        write_document(document, rendered)
        stdout.puts "#{index + 1}/#{documents.size} translated #{document.entry.kind}: #{document.entry.slug}"
      end
      compact_cache!(translations) unless only
      {
        branch: branch, files: documents.size, units: @units.size,
        cached_units: translations.size, cache: cache_path
      }
    end

    private

    def entries(only: nil)
      paths = Dir[File.join(root, 'HTML/{Discourses,Books}/*.html')].sort
      values = paths.map do |path|
        kind = path.include?('/Discourses/') ? :discourse : :book
        Entry.new(kind: kind, path: path)
      end
      return values unless only

      selected = values.find { |entry| entry.slug == only }
      [selected || raise("EWPRS entry not found: #{only}")]
    end

    def prepare_documents(entries)
      @units.clear
      @protected = 0
      @validated_cached_translations = nil
      entries.map do |entry|
        raw, encoding = read_document(entry.path)
        Document.new(
          entry: entry, template: unitize(raw), encoding: encoding, mode: source_mode(entry.path), raw: raw
        )
      end
    end

    def read_document(path)
      bytes = source_bytes(path)
      utf8  = bytes.dup.force_encoding(Encoding::UTF_8)
      return [utf8, Encoding::UTF_8] if utf8.valid_encoding?

      [bytes.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8), Encoding::Windows_1252]
    end

    def source_bytes(path)
      return File.binread(path) unless git_worktree?

      relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
      output, error, status = Open3.capture3(
        'git', 'show', "#{source_ref}:#{relative}", chdir: root, binmode: true
      )
      raise "cannot read #{relative} from #{source_ref}: #{error.strip}" unless status.success?

      output
    end

    def source_mode(path)
      return File.stat(path).mode & 0o7777 unless git_worktree?

      relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
      output = git('ls-tree', source_ref, '--', relative)
      mode = output.split.first
      raise "cannot read mode for #{relative} from #{source_ref}" unless mode

      Integer(mode, 8) & 0o7777
    end

    def git_worktree?
      return @git_worktree unless @git_worktree.nil?

      _output, _error, status = Open3.capture3(
        'git', 'rev-parse', '--is-inside-work-tree', chdir: root
      )
      @git_worktree = status.success?
    end

    def unitize(html)
      @document_protected = {}
      template = html.gsub(PROTECTED_ELEMENT) do |value|
        protect_content(value)
      end
      template = template.gsub(INLINE_ORIGINAL) do |value|
        protect_content(value)
      end
      template = template.gsub(BLOCK_CONTENT) do
        opening, content, closing = Regexp.last_match.captures
        "#{opening}#{register_content(content)}#{closing}"
      end
      template = unitize_grouped(template, GROUPED_PARAGRAPH)
      template = unitize_grouped(template, GROUPED_DIV)
      template = template.gsub(TEXT_NODE) do |value|
        translatable?(value) ? register_content(value) : value
      end
      @document_protected.each { |marker, value| template.gsub!(marker, value) }
      template
    ensure
      @document_protected = nil
    end

    def protect_content(value)
      @document_protected ||= {}
      marker = "⟦P#{Digest::SHA256.hexdigest(value)[0, 16]}⟧"
      @document_protected[marker] = value
      @protected += 1
      marker
    end

    def unitize_grouped(template, pattern)
      template.gsub(pattern) do
        content = Regexp.last_match(2)
        translated = translatable?(content) ? register_content(content) : content
        "#{Regexp.last_match(1)}#{translated}#{Regexp.last_match(3)}"
      end
    end

    def translatable?(value)
      core = value.to_s.strip
      return false if core.empty? || core.match?(UNIT_MARKER)
      return false if validator.protected_source_fragment?(core)

      core.gsub(PROTECTED_MARKER, '').match?(/[A-Za-z]/)
    end

    def register_unit(source)
      key = Digest::SHA256.hexdigest([PROMPT_VERSION, target, source].join("\0"))
      @units[key] ||= prepare_unit(key, source)
      "⟦U#{key}⟧"
    end

    def register_content(source)
      return protect_content(source) if non_english_verse?(source)

      source.split(/(#{STRUCTURAL_MARKUP})/).map do |part|
        if part.empty?
          part
        elsif part.match?(/\A#{STRUCTURAL_MARKUP}\z/)
          part
        else
          translatable?(part) ? register_sentences(part) : part
        end
      end.join
    end

    def register_sentences(source)
      leading = source[/\A\s*/m]
      trailing = source[/\s*\z/m]
      core = source[leading.length, source.length - leading.length - trailing.length]
      if core.match?(/\A#{EDITORIAL_CONTENT}\z/)
        opening, content, closing = editorial_parts(core)
        return "#{leading}#{opening}#{register_sentences(content)}#{closing}#{trailing}"
      end

      tags = {}
      masked = mask(source, MARKUP, tags)
      masked = mask_editorial_boundaries(masked, tags)
      sentences = SentenceSplitter.split(masked, boundary_tokens: PLACEHOLDER, max_chars: MAX_UNIT_CHARS)
      cursor = 0

      sentences.each_with_object(+'') do |sentence, template|
        index = masked.index(sentence, cursor)
        raise 'sentence splitter changed source content' unless index

        template << restore_split_markup(masked[cursor...index], tags)
        value = restore_split_markup(sentence, tags)
        template << (translatable?(value) ? register_unit(value) : value)
        cursor = index + sentence.length
      end << restore_split_markup(masked[cursor..], tags)
    end

    def mask_editorial_boundaries(source, tags)
      depth = 0
      source.gsub(/\[+|\]+|[.!?]+/) do |match|
        if match.start_with?('[')
          depth += match.length
          match
        elsif match.start_with?(']')
          depth = [depth - match.length, 0].max
          match
        elsif depth.positive?
          marker = format('__P%04d__', tags.size + 1)
          tags[marker] = match
          marker
        else
          match
        end
      end
    end

    def restore_split_markup(value, tags)
      value.to_s.gsub(PLACEHOLDER) { |token| tags.fetch(token) }
    end

    def non_english_verse?(source)
      validator.protected_source_fragment?(source)
    end

    def english_function_word?(word)
      %w[
        a an and are as at be been but by can did do does for from had has have he her him
        his i if in is it its my not of on or our she that the their them they this to was we
        were what when which who will with would you your
      ].include?(word.downcase)
    end

    def prepare_unit(key, source)
      leading = source[/\A\s*/m]
      trailing = source[/\s*\z/m]
      core = source[leading.length, source.length - leading.length - trailing.length]
      tokens = {}
      prepared = mask_dense_parentheticals(core)
      prepared = mask_sanskrit_glosses(prepared)
      prepared = tag_editorial_content(prepared, tokens)
      prepared = prepared.gsub(PROTECTED_MARKER) do |protected_marker|
        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = resolve_document_protected(protected_marker)
        marker
      end
      prepared = mask(prepared, PARTED_PUBLICATION_TITLE, tokens)
      prepared = mask(prepared, DATED_PUBLICATION_TITLE, tokens)
      prepared = mask(prepared, NUMBERED_SERIES_TITLE, tokens)
      prepared = mask(prepared, ITALIC_CITATION_TITLE, tokens)
      prepared = mask(prepared, ITALIC_EDITION_TITLE, tokens)
      prepared = mask(prepared, BOOK_TITLE, tokens)
      prepared = mask(prepared, SEE_PARENTHETICAL_TITLE, tokens)
      prepared = mask(prepared, EDITIONED_TITLE, tokens)
      prepared = mask(prepared, VOLUME_CITATION_TITLE, tokens)
      prepared = mask(prepared, PUBLICATION_LIST, tokens)
      prepared = mask(prepared, MAGAZINE_LIST, tokens)
      prepared = mask_foreign_inline(prepared, tokens)
      prepared = @lexicon.mask_inline(prepared, tokens)
      prepared = mask_named_marked_groups(prepared, tokens)
      prepared = mask(prepared, BIBLIOGRAPHIC_TITLE, tokens)
      prepared = mask(prepared, UNQUOTED_PUBLICATION_TITLE, tokens)
      prepared = mask_quoted_publication_titles(prepared, tokens)
      prepared = mask_quoted_language_examples(prepared, tokens)
      prepared = mask_title_case_quotes(prepared, tokens)
      prepared = mask(prepared, MARKUP, tokens)
      prepared = expose_editorial_tags(prepared)
      prepared = mask(prepared, EDITORIAL_BRACKET, tokens)
      prepared = mask(prepared, PAIRED_DELIMITER, tokens)
      prepared = mask(prepared, MARKED_WORD, tokens)
      prepared = mask(prepared, TECHNICAL_VALUE, tokens)
      prepared = mask(prepared, INDIC_SCRIPT, tokens)
      prepared = @lexicon.mask(prepared, tokens)
      prepared = coalesce_adjacent_terms(prepared, tokens)
      prepared = prepared.gsub(COORDINATED_PLACEHOLDER) do
        match = Regexp.last_match
        "#{match[:first]} #{match[:term]} and #{match[:second]} ones"
      end
      tokens.transform_values! do |value|
        restore_token_editorial_markers(resolve_document_protected_value(value))
      end
      prepared, tokens = canonicalize_placeholders(prepared, tokens)
      prepared = CGI.unescapeHTML(prepared)
      WINDOWS_CONTROLS.each { |from, to| prepared.gsub!(from, to) }
      missing = prepared.scan(PLACEHOLDER).uniq - tokens.keys
      raise "prepared unit #{key} has unregistered placeholders: #{missing.join(', ')}" unless missing.empty?

      Unit.new(
        key: key,
        source: resolve_unit_source(source),
        prepared: prepared, tokens: tokens,
        leading: leading, trailing: trailing
      )
    end

    def resolve_unit_source(source)
      resolved = resolve_document_protected_value(source).gsub(UNIT_MARKER) do
        @units.fetch(Regexp.last_match(1)).source
      end
      restore_token_editorial_markers(resolved)
    end

    def canonicalize_placeholders(source, tokens)
      ordered = source.scan(PLACEHOLDER).uniq
      reachable = ordered.dup
      reachable.each do |marker|
        tokens.fetch(marker).scan(PLACEHOLDER).each do |nested|
          reachable << nested unless reachable.include?(nested)
        end
      end
      unused = tokens.keys - reachable
      raise "prepared unit has unused placeholders: #{unused.join(', ')}" unless unused.empty?

      resolved = ordered.to_h { |marker| [marker, resolve_token_value(marker, tokens)] }
      first_marker_by_value = {}
      aliases = resolved.to_h do |marker, value|
        [marker, first_marker_by_value[value] ||= marker]
      end
      source = source.gsub(PLACEHOLDER) { |marker| aliases.fetch(marker) }
      ordered = source.scan(PLACEHOLDER).uniq
      replacements = ordered.each_with_index.to_h do |marker, index|
        [marker, format('__P%04d__', index + 1)]
      end
      prepared = source.gsub(PLACEHOLDER) { |marker| replacements.fetch(marker) }
      canonical = ordered.to_h do |marker|
        [replacements.fetch(marker), resolved.fetch(marker)]
      end
      [prepared, canonical]
    end

    def resolve_document_protected(marker, stack = [])
      raise "cyclic document protection: #{[*stack, marker].join(' -> ')}" if stack.include?(marker)

      resolve_document_protected_value(@document_protected.fetch(marker), [*stack, marker])
    end

    def resolve_document_protected_value(value, stack = [])
      value.gsub(PROTECTED_MARKER) { |nested| resolve_document_protected(nested, stack) }
    end

    def restore_token_editorial_markers(value)
      value.gsub(/⟦E([12])([12])⟧/) { '[' * Regexp.last_match(1).to_i }
        .gsub(%r{⟦/E([12])([12])⟧}) { ']' * Regexp.last_match(2).to_i }
    end

    def resolve_token_value(marker, tokens, stack = [])
      raise "cyclic protected placeholders: #{[*stack, marker].join(' -> ')}" if stack.include?(marker)

      tokens.fetch(marker).gsub(PLACEHOLDER) do |nested|
        resolve_token_value(nested, tokens, [*stack, marker])
      end
    end

    def coalesce_adjacent_terms(source, tokens)
      loop do
        changed = false
        source = source.gsub(ADJACENT_PROTECTED_TERMS) do |match|
          left, spacing, right = Regexp.last_match.values_at(:left, :spacing, :right)
          if plain_protected_term?(tokens.fetch(left)) && plain_protected_term?(tokens.fetch(right))
            tokens[left] = "#{tokens.fetch(left)}#{spacing}#{tokens.delete(right)}"
            changed = true
            left
          else
            match
          end
        end
        return source unless changed
      end
    end

    def plain_protected_term?(value)
      !value.match?(/[<>⟦⟧()\[\]{}]/)
    end

    def mask_sanskrit_glosses(source)
      masked = mask_glosses(source, QUOTED_GLOSS)
      masked = mask_coordinated_with_glosses(masked)
      masked = mask_coordinated_bracketed_glosses(masked)
      masked = mask_coordinated_parenthetical_glosses(masked)
      masked = mask_glosses(masked, @lexicon.inline_gloss_pattern)
      masked = mask_glosses(masked, MARKED_INLINE_GLOSS)
      masked = mask_glosses(masked, MARKED_PHRASE_GLOSS)
      masked = mask_glosses(masked, DEFINED_TERM_GLOSS)
      masked = mask_glosses(masked, HYPHENATED_TERM_GLOSS)
      masked = mask_glosses(masked, CONSONANT_TERM_GLOSS)
      masked = mask_glosses(masked, @lexicon.gloss_pattern)
      mask_proper_noun_glosses(masked)
    end

    def mask_coordinated_with_glosses(source)
      source.gsub(COORDINATED_WITH_GLOSSES) do
        captures = Regexp.last_match
        first = nested_bracketed_gloss(captures, :first)
        second = nested_bracketed_gloss(captures, :second)
        "#{captures[:prefix]}#{first}#{captures[:coordination]}#{second}"
      end
    end

    def mask_proper_noun_glosses(source)
      source.gsub(PROPER_NOUN_GLOSS) do |match|
        prefix, term, spacing, opening, gloss, closing = Regexp.last_match.values_at(
          :prefix, :term, :spacing, :opening, :gloss, :closing
        )
        next match if english_function_word?(term) || !translatable?(gloss)

        "#{prefix}#{protect_content("#{term}#{spacing}#{opening}#{register_unit(gloss)}#{closing}")}"
      end
    end

    def mask_coordinated_bracketed_glosses(source)
      source.gsub(COORDINATED_BRACKETED_GLOSSES) do
        captures = Regexp.last_match
        first = nested_bracketed_gloss(captures, :first)
        second = nested_bracketed_gloss(captures, :second)
        "#{first}#{captures[:coordination]}#{second}"
      end
    end

    def nested_bracketed_gloss(captures, prefix)
      term, spacing, opening, gloss, closing = %i[term spacing opening gloss closing].map do |part|
        captures["#{prefix}_#{part}".to_sym]
      end
      translated = translatable?(gloss) ? register_unit(gloss) : gloss
      protect_content("#{term}#{spacing}#{opening}#{translated}#{closing}")
    end

    def mask_coordinated_parenthetical_glosses(source)
      source.gsub(COORDINATED_PARENTHETICAL_GLOSSES) do |match|
        captures = Regexp.last_match
        first_term, second_term = captures.values_at(:first_term, :second_term)
        next match unless [first_term, second_term].any? { |term| term.match?(MARKED_WORD) }

        first = nested_parenthetical_gloss(
          first_term, captures[:first_spacing], captures[:first_gloss]
        )
        second = nested_parenthetical_gloss(
          second_term, captures[:second_spacing], captures[:second_gloss]
        )
        "#{first}#{captures[:coordination]}#{second}"
      end
    end

    def nested_parenthetical_gloss(term, spacing, gloss)
      translated = translatable?(gloss) ? register_unit(gloss) : gloss
      protect_content("#{term}#{spacing}(#{translated})")
    end

    def mask_dense_parentheticals(source)
      source.gsub(PARENTHETICAL_CONTENT) do |match|
        content = Regexp.last_match[:content]
        next match if content.scan(MARKED_WORD).size < 2

        nested = translatable?(content) ? register_unit(content) : content
        protect_content("(#{nested})")
      end
    end

    def mask_foreign_inline(source, tokens)
      source.gsub(FOREIGN_INLINE) do |match|
        content = Regexp.last_match[:content]
        next match unless validator.protected_inline_fragment?(content)

        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = match
        marker
      end
    end

    def mask_named_marked_groups(source, tokens)
      source.gsub(NAMED_MARKED_GROUP) do |match|
        captures = Regexp.last_match
        prefix   = captures[:prefix]
        group    = CGI.unescapeHTML(captures[:group]).unicode_normalize(:nfd).gsub(/\p{M}/, '')
        next match unless group.end_with?('s')

        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = match.delete_prefix(prefix)
        "#{prefix}#{marker}"
      end
    end

    def mask_quoted_publication_titles(source, tokens)
      source.gsub(QUOTED_PUBLICATION_TITLE) do
        prefix, title = Regexp.last_match.values_at(:prefix, :title)
        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = title
        "#{prefix}#{marker}"
      end
    end

    def mask_quoted_language_examples(source, tokens)
      source.gsub(QUOTED_LANGUAGE_EXAMPLE) do
        match = Regexp.last_match
        prefix, example = match.values_at(:prefix, :example)
        if prefix.match?(/\b(?:say|says|said)\b/i)
          linguistic_context = match.pre_match.match?(
            /(?:\bIn\s+English\b|\b(?:word|phrase|sentence|expression|term|language)\b)[^.!?]{0,240}\z/i
          )
          next match[0] unless linguistic_context
        end

        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = example
        "#{prefix}#{marker}"
      end
    end

    def mask_title_case_quotes(source, tokens)
      source.gsub(QUOTED_TITLE) do |match|
        preceding = Regexp.last_match.pre_match
        following = Regexp.last_match.post_match
        provenance = following.match?(
          /\A\s+(?:(?:comes?|came)\s+from|is\s+thought\s+to\s+(?:be|have\s+come)\s+from)\b/i
        ) || (preceding.match?(/,\s+and\s+\z/i) && following.match?(/\A\s+from\b/i))
        next match unless provenance

        words = CGI.unescapeHTML(match.gsub(/&[a-z]+;/i, ' ')).scan(/[A-Za-z][A-Za-z'’-]*/)
        capitalized = words.count { |word| word.match?(/\A[A-Z]/) }
        title_case = words.all? do |word|
          word.match?(/\A[A-Z]/) || TITLE_CONNECTORS.include?(word.downcase)
        end
        next match unless capitalized >= 3 && title_case

        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = match
        marker
      end
    end

    def mask_glosses(source, pattern)
      source.gsub(pattern) do |match|
        captures = Regexp.last_match
        term, spacing, opening, gloss, closing = captures.values_at(
          :term, :spacing, :opening, :gloss, :closing
        )
        suffix = captures.names.include?('suffix') ? captures[:suffix] : nil
        next match unless translatable?(gloss)
        if pattern == MARKED_PHRASE_GLOSS
          words = CGI.unescapeHTML(term).scan(/[A-Za-z][A-Za-z'’-]*/)
          next match if words.any? { |word| english_function_word?(word) }
        end

        protect_content("#{term}#{spacing}#{opening}#{register_unit(gloss)}#{closing}#{suffix}")
      end
    end

    def tag_editorial_content(source, tokens)
      editorial_counts = source.scan(EDITORIAL_CONTENT).tally
      source = source.gsub(HYPHENATED_EDITORIAL) do |match|
        prefix, editorial = Regexp.last_match.values_at(:prefix, :editorial)
        opening, content, closing = editorial_parts(editorial)
        next match unless translatable?(content)

        depth = "#{opening.length}#{closing.length}"
        "⟦E#{depth}⟧#{prefix}-#{content}⟦/E#{depth}⟧"
      end
      source = source.gsub(ATTACHED_EDITORIAL) do |match|
        prefix, editorial = Regexp.last_match.values_at(:prefix, :editorial)
        opening, content, closing = editorial_parts(editorial)
        next match unless translatable?(content)

        depth = "#{opening.length}#{closing.length}"
        "⟦E#{depth}⟧#{prefix}#{content}⟦/E#{depth}⟧"
      end
      source.gsub(EDITORIAL_CONTENT) do
        editorial = Regexp.last_match[0]
        opening, content, closing = editorial_parts(editorial)
        if translatable?(content)
          quoted = content.match?(/\A&(?:ldquo|quot);.*&(?:rdquo|quot);\z/i)
          sentence_bearing = content.match?(/[.!?]\s+[A-Z]/) && !quoted
          lexical_completion = content.match?(/\A[A-Za-z]+(?:['’-][A-Za-z]+)*\z/) &&
                               Regexp.last_match.pre_match.match?(/\b[a-z][A-Za-z'’-]*\s+\z/)
          if opening.length == 2 || closing.length == 2 ||
             content.length > MAX_INLINE_EDITORIAL_CHARS ||
             sentence_bearing || lexical_completion || editorial_counts.fetch(editorial, 0) > 1 ||
             content.match?(/\b[A-Za-z]+-[A-Za-z]+\b/)
            next protect_content("#{opening}#{register_sentences(content)}#{closing}")
          end

          depth = "#{opening.length}#{closing.length}"
          next "⟦E#{depth}⟧#{content}⟦/E#{depth}⟧"
        end

        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = "#{opening}#{content}#{closing}"
        marker
      end
    end

    def expose_editorial_tags(source)
      source.gsub(/⟦E([12])([12])⟧/, '<span data-ewprs="\1\2">')
        .gsub(%r{⟦/E[12][12]⟧}, '</span>')
    end

    def editorial_parts(value)
      opening = value[/\A\[\[?/]
      closing = value[/\]\]?\z/]
      [opening, value[opening.length...-closing.length], closing]
    end

    def mask(value, pattern, tokens)
      value.gsub(pattern) do |match|
        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = match
        marker
      end
    end

    def translate_units
      translations = validated_cached_translations.dup
      pending = @units.values.reject { |unit| translations.key?(unit.key) }
      return translations if pending.empty?

      FileUtils.mkdir_p(File.dirname(cache_path))
      store = JsonlStore.new(cache_path)
      pending.each_slice(BATCH_SIZE).with_index do |batch, batch_index|
        outputs = Array(
          translator.translate_markup(batch.map(&:prepared), from: source_language, to: target)
        )
        raise "translation count mismatch: expected #{batch.size}, got #{outputs.size}" unless outputs.size == batch.size

        batch.zip(outputs).each do |unit, output|
          translation = restore_tokens_with_retries(unit, output)
          translations[unit.key] = translation
          cached_translations[unit.key] = translation
          store.append(key: unit.key, translation: translation, at: Time.now.utc.iso8601)
        end
        stdout.puts "translated batch #{batch_index + 1}: #{translations.size}/#{@units.size} units cached"
      end
      translations
    end

    def restore_tokens_with_retries(unit, output)
      retries = 0
      begin
        validator.validate!(source: unit.prepared, translated: output)
        restore_tokens(unit, output)
      rescue ProtectedTokenError, TranslationValidator::Error => error
        raise if retries >= TOKEN_RETRIES

        retries += 1
        stdout.puts "retrying invalid translation #{unit.key} (#{retries}/#{TOKEN_RETRIES}): #{error.message}"
        output = translator.repair_markup(
          unit.prepared, invalid: output, issue: error.message,
          tokens: repair_token_values(unit.tokens), from: source_language, to: target
        )
        retry
      end
    end

    def repair_token_values(tokens)
      tokens.transform_values do |value|
        value.gsub(UNIT_MARKER) { @units.fetch(Regexp.last_match(1)).source }
      end
    end

    def restore_tokens(unit, output)
      output = normalize_protected_boundaries(unit, output.to_s)
      expected = unit.prepared.scan(PLACEHOLDER)
      actual   = output.scan(PLACEHOLDER)
      unless actual.tally == expected.tally
        expected_counts = expected.tally
        actual_counts   = actual.tally
        missing = expected_counts.flat_map do |marker, count|
          [marker] * [count - actual_counts.fetch(marker, 0), 0].max
        end
        unexpected = actual_counts.flat_map do |marker, count|
          [marker] * [count - expected_counts.fetch(marker, 0), 0].max
        end
        details = []
        details << "missing: #{missing.join(', ')}" unless missing.empty?
        details << "unexpected: #{unexpected.join(', ')}" unless unexpected.empty?
        raise ProtectedTokenError,
              "translation changed protected tokens for #{unit.key} (#{details.join('; ')})"
      end

      unless output.scan(EDITORIAL_TAG) == unit.prepared.scan(EDITORIAL_TAG)
        raise ProtectedTokenError, "translation changed editorial tags for #{unit.key}"
      end
      unless valid_editorial_structure?(unit, output)
        raise ProtectedTokenError, "translation changed editorial tags for #{unit.key}"
      end

      unless valid_structural_order?(unit, expected, actual) && valid_structural_adjacency?(unit, output)
        raise ProtectedTokenError, "translation reordered structural tokens for #{unit.key}"
      end

      translated = restore_editorial_tags(output).split(/(#{PLACEHOLDER})/).map do |part|
        unit.tokens.fetch(part) { preserve_entities(CGI.escapeHTML(part)) }
      end.join
      validate_restored_translation!(unit, "#{unit.leading}#{translated}#{unit.trailing}")
    end

    def normalize_protected_boundaries(unit, output)
      unit.tokens.each_with_object(output.dup) do |(marker, value), normalized|
        visible = CGI.unescapeHTML(value.gsub(MARKUP, ' ').gsub(UNIT_MARKER, ' ')).strip
        normalized.gsub!(/(?<=\p{L})#{Regexp.escape(marker)}/u, " #{marker}") if visible.match?(/\A\p{L}/u)
        normalized.gsub!(/#{Regexp.escape(marker)}(?=\p{L})/u, "#{marker} ") if visible.match?(/\p{L}\z/u)
      end
    end

    def restore_editorial_tags(value)
      closing_depths = []
      restored = value.gsub(EDITORIAL_TAG) do |tag|
        if tag.match?(/\A<span/i)
          opening, closing = tag.match(/data-ewprs="([12])([12])"/i).captures
          closing_depths << closing.to_i
          '[' * opening.to_i
        else
          closing = closing_depths.pop
          raise ProtectedTokenError, 'translation left editorial tags unbalanced' unless closing

          ']' * closing
        end
      end
      raise ProtectedTokenError, 'translation left editorial tags unbalanced' unless closing_depths.empty?

      restored
    end

    def valid_structural_order?(unit, expected, actual)
      expected_structure = expected.select { |token| structural_token?(unit.tokens.fetch(token)) }
      actual_structure   = actual.select { |token| structural_token?(unit.tokens.fetch(token)) }
      return true if actual_structure == expected_structure

      pairs = movable_inline_pairs(expected_structure, unit.tokens)
      return false if pairs.empty?

      movable = pairs.flatten.to_h { |token| [token, true] }
      expected_anchors = expected_structure.reject { |token| movable.key?(token) }
      actual_anchors   = actual_structure.reject { |token| movable.key?(token) }
      return false unless actual_anchors == expected_anchors

      pairs.all? do |opening, closing|
        expected_index = expected_structure.index(opening)
        actual_index   = actual_structure.index(opening)
        next false unless actual_index && actual_structure[actual_index + 1] == closing

        expected_structure[..expected_index].count { |token| !movable.key?(token) } ==
          actual_structure[..actual_index].count { |token| !movable.key?(token) }
      end
    end

    def valid_structural_adjacency?(unit, output)
      structural_adjacencies(unit.prepared, unit.tokens).tally ==
        structural_adjacencies(output, unit.tokens).tally
    end

    def valid_editorial_structure?(unit, output)
      return true unless unit.prepared.match?(EDITORIAL_TAG)

      editorial_structure(unit.prepared, unit.tokens) == editorial_structure(output, unit.tokens)
    end

    def editorial_structure(value, tokens)
      value.to_s.scan(/#{PLACEHOLDER}|#{EDITORIAL_TAG}/).select do |part|
        part.match?(EDITORIAL_TAG) || begin
          protected = tokens.fetch(part)
          structural_token?(protected) || protected.match?(PAIRED_DELIMITER)
        end
      end
    end

    def structural_adjacencies(value, tokens)
      value.to_s.scan(/(?=(#{PLACEHOLDER})(#{PLACEHOLDER}))/).select do |left, right|
        structural_token?(tokens.fetch(left)) && structural_token?(tokens.fetch(right))
      end
    end

    def movable_inline_pairs(structure, tokens)
      structure.each_cons(2).filter_map do |opening, closing|
        opening_tag = tokens.fetch(opening)[/\A<(i|em)\b[^>]*>\z/i, 1]
        closing_tag = tokens.fetch(closing)[/\A<\/(i|em)\s*>\z/i, 1]
        [opening, closing] if opening_tag && closing_tag&.casecmp?(opening_tag)
      end
    end

    def structural_token?(value)
      value.match?(STANDALONE_MARKUP) || value.match?(/\A#{EDITORIAL_BRACKET}\z/)
    end

    def cached_translations
      @cached_translations ||= JsonlStore.new(cache_path).each_with_object({}) do |record, values|
        values[record.fetch(:key)] = preserve_entities(record.fetch(:translation))
      end
    end

    def validated_cached_translations
      @validated_cached_translations ||= @units.each_with_object({}) do |(key, unit), values|
        translation = cached_translations[key]
        next unless translation

        begin
          unless cached_nested_markers_valid?(unit, translation)
            raise TranslationValidator::Error.new(
              :nested_units, 'translation has stale nested unit markers'
            )
          end

          validate_restored_translation!(unit, translation)
          values[key] = translation
        rescue TranslationValidator::Error => error
          stdout.puts "discarding invalid cached translation #{key}: #{error.message}"
        end
      end
    end

    def validate_restored_translation!(unit, translation)
      protected_values = protected_value_counts(unit)
      progress_values = protected_values.reject { |value, _count| value.match?(UNIT_MARKER) }
      validation_source, validation_translation = project_nested_values(unit, translation)
      validator.validate!(
        source: validation_source, translated: validation_translation,
        protected_values: progress_values
      )
      validator.validate_protected!(
        source: unit.source, translated: translation, protected_values: protected_values
      )
      translation
    end

    def project_nested_values(unit, translation)
      nested_tokens = unit.tokens.select { |_marker, value| value.match?(UNIT_MARKER) }
      return [unit.source.dup, translation.dup] if nested_tokens.empty?

      source = restore_editorial_tags(unit.prepared).gsub(PLACEHOLDER) do |marker|
        unit.tokens.fetch(marker)
      end
      translated = translation.dup
      nested_tokens.each do |marker, value|
        unit.prepared.scan(marker).size.times do
          unless source.sub!(value, '__P9999__') && translated.sub!(value, '__P9999__')
            raise TranslationValidator::Error.new(
              :nested_units, "translation changed nested token structure for #{unit.key}"
            )
          end
        end
      end
      [source, translated]
    end

    def cached_nested_markers_valid?(unit, translation)
      expected = unit.tokens.flat_map do |marker, value|
        value.scan(UNIT_MARKER) * unit.prepared.scan(marker).size
      end
      translation.scan(UNIT_MARKER).tally == expected.tally
    end

    def compact_cache!(translations)
      FileUtils.mkdir_p(File.dirname(cache_path))
      temp = "#{cache_path}.tmp"
      timestamp = Time.now.utc.iso8601
      File.open(temp, 'w') do |file|
        @units.each_key do |key|
          file.puts JSON.generate(key: key, translation: translations.fetch(key), at: timestamp)
        end
        file.flush
        file.fsync
      end
      File.rename(temp, cache_path)
    ensure
      FileUtils.rm_f(temp) if temp && File.exist?(temp)
    end

    def protected_value_counts(unit)
      unit.tokens.each_with_object(Hash.new(0)) do |(marker, value), counts|
        counts[value] += unit.prepared.scan(marker).size
      end
    end

    def resolve_nested_translation(value, seen = {})
      value.gsub(UNIT_MARKER) do |marker|
        key = Regexp.last_match(1)
        next marker if seen.key?(key) || !cached_translations.key?(key)

        resolve_nested_translation(cached_translations.fetch(key), seen.merge(key => true))
      end
    end

    def preserve_entities(value)
      value.gsub(ESCAPED_ENTITY, '&')
    end

    def render(document, translations)
      rendered = document.template
      rendered = rendered.gsub(UNIT_MARKER) { translations.fetch(Regexp.last_match(1)) } while rendered.match?(UNIT_MARKER)
      rendered
    end

    def validate_structure!(source, translated)
      source_structure = source.scan(/<!--.*?-->|<[^>]+>/m)
      translated_structure = translated.scan(/<!--.*?-->|<[^>]+>/m)
      raise 'HTML structure changed during translation' unless translated_structure == source_structure

      source_slokas = matches(source, PROTECTED_ELEMENT).select { |value| value.match?(/Para_Sloka/) }
      translated_slokas = matches(translated, PROTECTED_ELEMENT).select { |value| value.match?(/Para_Sloka/) }
      raise 'Para_Sloka content changed during translation' unless translated_slokas == source_slokas

      source_brackets     = source.scan(EDITORIAL_BRACKET)
      translated_brackets = translated.scan(EDITORIAL_BRACKET)
      raise 'editorial brackets changed during translation' unless translated_brackets == source_brackets
    end

    def matches(value, pattern)
      value.to_enum(:scan, pattern).map { Regexp.last_match[0] }
    end

    def write_document(document, rendered)
      bytes = rendered.encode(document.encoding)
      temp  = "#{document.entry.path}.translation.tmp"
      File.binwrite(temp, bytes)
      File.chmod(document.mode, temp)
      File.rename(temp, document.entry.path)
    ensure
      FileUtils.rm_f(temp) if temp && File.exist?(temp)
    end

    def class_inventory(documents)
      counts = CONTENT_CLASSES.to_h { |name| [name, 0] }
      documents.each do |html|
        CONTENT_CLASSES.each do |name|
          pattern = name == 'center' ? /<center\b/i : /\bclass\s*=\s*["']?#{Regexp.escape(name)}\b/i
          counts[name] += 1 if html.match?(pattern)
        end
      end
      counts
    end

    def prepare_branch!
      current = git('branch', '--show-current').strip
      return if current == branch

      raise "EWPRS worktree must be clean before switching branches" unless git('status', '--porcelain').strip.empty?
      raise "expected branch #{source_ref}, got #{current}" unless current == source_ref

      exists = system('git', 'show-ref', '--verify', '--quiet', "refs/heads/#{branch}", chdir: root)
      exists ? git('switch', branch) : git('switch', '-c', branch, source_ref)
    end

    def git(*args)
      output, error, status = Open3.capture3('git', *args, chdir: root)
      raise "git #{args.join(' ')} failed: #{error.strip}" unless status.success?

      output
    end

    class SanskritLexicon
      DEFAULT_TERMS = %w[
        Brahma Shiva Shakti Prakrti Purusa Purusottama dharma Tantra yoga
        sadhana samadhi mantra kiirtana tattva vrtti pravrtti nivrtti samskara
        amrta caetanya hasant madhyama mudra nrtya pratibha sarjana sargam srjanii
        Shivatattva utsarjana vilambita visarjana
        pra karoti iti
      ].freeze

      attr_reader :gloss_pattern, :inline_gloss_pattern

      def initialize(root)
        path = File.join(root, 'HTML/Info/MasterGlossary.html')
        raw = File.binread(path)
        html = raw.dup.force_encoding(Encoding::UTF_8)
        html = raw.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8) unless html.valid_encoding?
        document = Nokogiri::HTML5.parse(html)
        @terms = document.css('b').flat_map { |node| variants(node.text) }
        @terms.concat(DEFAULT_TERMS)
        @terms = @terms.map(&:strip).reject { |term| term.length < 3 }.uniq.sort_by { |term| -term.length }
        @pattern = /(?<![A-Za-z])(?:#{@terms.map { |term| Regexp.escape(term) }.join('|')})(?![A-Za-z])/i
        @inline_pattern = %r{<(?<tag>i|em)\b[^>]*>\s*#{@pattern}\s*</\k<tag>\s*>}i
        @inline_gloss_pattern = %r{
          (?<term>#{@inline_pattern})(?<spacing>\s*)
          (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
        }ix
        @gloss_pattern = %r{
          (?<term>(?:#{MARKED_WORD}|#{ASCII_TRANSLITERATED_WORD}|#{@pattern}))(?<spacing>\s*)
          (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
          (?<suffix>\s+(?<![A-Za-z])(?-i:[A-Z])[A-Za-z'’-]*(?![A-Za-z]))?
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
end
