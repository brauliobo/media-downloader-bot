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

module Ewprs
  class TranslationBatch
    CONTENT_CLASSES = %w[
      Para_Major_Heading Para_Minor_Heading Para_Indent plain Para_Sloka
      Para_Translation_Eds Para_Citation Para_Quote Para_Footnote center
    ].freeze
    PROMPT_VERSION = 10
    BATCH_SIZE     = 50
    MAX_UNIT_CHARS = 800
    TOKEN_RETRIES  = 2
    WINDOWS_CONTROLS = {
      "\u0085" => '...', "\u0091" => "'", "\u0092" => "'",
      "\u0093" => '"', "\u0094" => '"', "\u0096" => '-', "\u0097" => '--'
    }.freeze

    class ProtectedTokenError < StandardError; end

    Entry = Struct.new(:kind, :path, keyword_init: true) do
      def slug = File.basename(path, File.extname(path))
    end

    Document = Struct.new(:entry, :template, :encoding, :raw, keyword_init: true)
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
    FOOTNOTE          = /<!--\s*fn\s*-->.*?<!--\s*\/fn\s*-->/mi
    EDITORIAL_CONTENT = /\[\[?[^\[\]\r\n]+\]\]?/
    STRUCTURAL_MARKUP = %r{#{FOOTNOTE}|#{EDITORIAL_CONTENT}|<br\s*/?>|</?(?:table|thead|tbody|tfoot|tr|td|th|ul|ol|li)\b[^>]*>}i
    TEXT_NODE        = /(?<=>)([^<]+)(?=<)/m
    MARKED_WORD      = /(?<![A-Za-z])(?:[A-Za-z][A-Za-z'’-]*)(?:(?:&#x(?:301|32D);)[A-Za-z'’-]*)+(?![A-Za-z])/i
    MARKED_INLINE    = %r{<(?<tag>i|em)\b[^>]*>\s*#{MARKED_WORD}\s*</\k<tag>\s*>}i
    MARKED_INLINE_GLOSS = %r{
      (?<term><(?<tag>i|em)\b[^>]*>(?=[^<]*#{MARKED_WORD})[^<]*</\k<tag>>)(?<spacing>\s*)
      (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
    }ix
    EDITORIAL_BRACKET = /\[\[?|\]\]?/
    INLINE_ORIGINAL  = %r{
      (?<=,\s)
      (?<original>(?=(?:[A-Za-z]+\s+)?#{MARKED_WORD})[^<>\r\n]+?)
      \s+(?=\[(?:&(?:ldquo|quot);|["“]))
    }ix
    MARKUP           = /#{FOOTNOTE}|#{MARKED_INLINE}|<!--.*?-->|<[^>]+>/m
    INDIC_SCRIPT     = /[\p{Devanagari}\p{Bengali}]+/
    TECHNICAL_VALUE  = /(?:\bEE\d+(?:\.\d+)?\b|\b[^\s<>]+\.html\b)/i
    PLACEHOLDER      = /__P\d{4}__/
    QUANTIFIER       = /(?:one|two|three|four|five|six|seven|eight|nine|ten|\d+)/i
    COORDINATED_PLACEHOLDER = %r{
      (?<first>\b#{QUANTIFIER}\s+[A-Za-z-]+)\s+and\s+
      (?<second>#{QUANTIFIER}\s+[A-Za-z-]+)\s+(?<term>#{PLACEHOLDER})
    }ix
    PROTECTED_MARKER = /⟦P[0-9a-f]+⟧/
    UNIT_MARKER      = /⟦U([0-9a-f]{64})⟧/
    DOCUMENT_MARKER  = /#{PROTECTED_MARKER}|#{UNIT_MARKER}/
    ESCAPED_ENTITY   = /&amp;(?=(?:#\d+|#x[\da-f]+|[a-z][\w]+);)/i

    attr_reader :root, :target, :source_ref, :branch, :cache_path, :translator, :stdout

    def initialize(root:, target: 'pt', source_ref: '7.5', branch: '7.5-pt', cache: nil,
                   translator: Translator.new, stdout: $stdout)
      @root       = File.expand_path(root)
      @target     = target
      @source_ref = source_ref
      @branch     = branch
      @cache_path = File.expand_path(cache || "tmp/ewprs_translations/#{branch}.jsonl", Dir.pwd)
      @translator = translator
      @stdout     = stdout
      @lexicon    = SanskritLexicon.new(@root)
      @units      = {}
      @protected  = 0
    end

    def plan(only: nil)
      documents = prepare_documents(entries(only: only))
      {
        root:              root,
        source_ref:        source_ref,
        branch:            branch,
        target:            target,
        files:             documents.size,
        classes:           class_inventory(documents.map(&:raw)),
        units:             @units.size,
        cached_units:      @units.keys.count { |key| cached_translations.key?(key) },
        untranslated_units: @units.keys.count { |key| !cached_translations.key?(key) },
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
      entries.map do |entry|
        raw, encoding = read_document(entry.path)
        Document.new(entry: entry, template: unitize(raw), encoding: encoding, raw: raw)
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
        elsif part.match?(/\A#{EDITORIAL_CONTENT}\z/)
          opening, content, closing = editorial_parts(part)
          translated = translatable?(content) ? register_content(content) : content
          "#{opening}#{translated}#{closing}"
        elsif part.match?(/\A#{STRUCTURAL_MARKUP}\z/)
          part
        else
          translatable?(part) ? register_sentences(part) : part
        end
      end.join
    end

    def register_sentences(source)
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
      return false unless source.match?(%r{<br\s*/?>}i)

      plain = CGI.unescapeHTML(source.gsub(MARKUP, ' '))
      words = plain.scan(/\p{L}[\p{L}\p{M}'’-]*/u)
      marked = words.count { |word| word.match?(/\p{M}/u) }
      english = words.count { |word| english_function_word?(word) }
      words.size >= 6 && marked >= 2 && marked.fdiv(words.size) >= 0.12 && english.fdiv(words.size) < 0.08
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
      prepared = core.gsub(PROTECTED_MARKER) do |protected_marker|
        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = @document_protected.fetch(protected_marker)
        marker
      end
      prepared = mask_sanskrit_glosses(prepared, tokens)
      prepared = mask_editorial_content(prepared, tokens)
      prepared = @lexicon.mask_inline(prepared, tokens)
      prepared = mask(prepared, MARKUP, tokens)
      prepared = mask(prepared, EDITORIAL_BRACKET, tokens)
      prepared = mask(prepared, MARKED_WORD, tokens)
      prepared = mask(prepared, TECHNICAL_VALUE, tokens)
      prepared = mask(prepared, INDIC_SCRIPT, tokens)
      prepared = @lexicon.mask(prepared, tokens)
      prepared = prepared.gsub(COORDINATED_PLACEHOLDER) do
        match = Regexp.last_match
        "#{match[:first]} #{match[:term]} and #{match[:second]} ones"
      end
      prepared = CGI.unescapeHTML(prepared)
      WINDOWS_CONTROLS.each { |from, to| prepared.gsub!(from, to) }
      Unit.new(
        key: key, source: source, prepared: prepared, tokens: tokens,
        leading: leading, trailing: trailing
      )
    end

    def mask_sanskrit_glosses(source, tokens)
      masked = mask_glosses(source, MARKED_INLINE_GLOSS, tokens)
      mask_glosses(masked, @lexicon.gloss_pattern, tokens)
    end

    def mask_glosses(source, pattern, tokens)
      source.gsub(pattern) do |match|
        term, spacing, opening, gloss, closing = Regexp.last_match.values_at(
          :term, :spacing, :opening, :gloss, :closing
        )
        next match unless translatable?(gloss)

        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = "#{term}#{spacing}#{opening}#{register_unit(gloss)}#{closing}"
        marker
      end
    end

    def mask_editorial_content(source, tokens)
      source.gsub(EDITORIAL_CONTENT) do
        opening, content, closing = editorial_parts(Regexp.last_match[0])
        translated = translatable?(content) ? register_unit(content) : content
        marker = format('__P%04d__', tokens.size + 1)
        tokens[marker] = "#{opening}#{translated}#{closing}"
        marker
      end
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
      translations = @units.keys.each_with_object({}) do |key, values|
        values[key] = cached_translations[key] if cached_translations.key?(key)
      end
      pending = @units.values.reject { |unit| translations.key?(unit.key) }
      return translations if pending.empty?

      FileUtils.mkdir_p(File.dirname(cache_path))
      store = JsonlStore.new(cache_path)
      pending.each_slice(BATCH_SIZE).with_index do |batch, batch_index|
        outputs = Array(translator.translate_markup(batch.map(&:prepared), to: target))
        raise "translation count mismatch: expected #{batch.size}, got #{outputs.size}" unless outputs.size == batch.size

        batch.zip(outputs).each do |unit, output|
          translation = restore_tokens_with_retries(unit, output)
          translations[unit.key] = translation
          store.append(key: unit.key, translation: translation, at: Time.now.utc.iso8601)
        end
        stdout.puts "translated batch #{batch_index + 1}: #{translations.size}/#{@units.size} units cached"
      end
      translations
    end

    def restore_tokens_with_retries(unit, output)
      retries = 0
      begin
        restore_tokens(unit, output)
      rescue ProtectedTokenError
        raise if retries >= TOKEN_RETRIES

        retries += 1
        stdout.puts "retrying protected-token translation #{unit.key} (#{retries}/#{TOKEN_RETRIES})"
        output = translator.repair_markup(unit.prepared, tokens: unit.tokens, to: target)
        retry
      end
    end

    def restore_tokens(unit, output)
      expected = unit.prepared.scan(PLACEHOLDER)
      actual   = output.to_s.scan(PLACEHOLDER)
      unless actual.tally == expected.tally
        raise ProtectedTokenError, "translation changed protected tokens for #{unit.key}"
      end

      expected_structure = expected.select { |token| structural_token?(unit.tokens.fetch(token)) }
      actual_structure   = actual.select { |token| structural_token?(unit.tokens.fetch(token)) }
      unless actual_structure == expected_structure
        raise ProtectedTokenError, "translation reordered structural tokens for #{unit.key}"
      end

      translated = output.to_s.split(/(#{PLACEHOLDER})/).map do |part|
        unit.tokens.fetch(part) { preserve_entities(CGI.escapeHTML(part)) }
      end.join
      "#{unit.leading}#{translated}#{unit.trailing}"
    end

    def structural_token?(value)
      value.start_with?('<') || value.match?(/\A#{EDITORIAL_BRACKET}\z/)
    end

    def cached_translations
      @cached_translations ||= JsonlStore.new(cache_path).each_with_object({}) do |record, values|
        values[record.fetch(:key)] = preserve_entities(record.fetch(:translation))
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
        sadhana samadhi mantra kiirtana vrtti pravrtti nivrtti samskara
        amrta caetanya hasant madhyama mudra nrtya sargam Shivatattva vilambita
      ].freeze

      attr_reader :gloss_pattern

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
        @gloss_pattern = %r{
          (?<term>(?:#{MARKED_WORD}|#{@pattern}))(?<spacing>\s*)
          (?<opening>\[\[?)(?<gloss>[^\[\]\r\n]+)(?<closing>\]\]?)
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
