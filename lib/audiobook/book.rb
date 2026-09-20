require 'json'
require 'yaml'
require 'set'
require 'fileutils'
require 'uri'
require 'date'
require_relative 'source_formats'
require_relative 'parsers/pdf'
require_relative 'parsers/epub'
require_relative 'parsers/html'
require_relative 'parsers/txt'
require_relative 'parsers/kindle'
require_relative '../text_helpers'
require_relative '../ocr'
require_relative '../language'
require_relative 'line'
require_relative 'font_roles'
require_relative 'sentence'
require_relative 'paragraph'
require_relative 'reference'
require_relative 'heading'
require_relative 'section'
require_relative 'image'
require_relative 'ocr_text'
require_relative 'page'
require_relative 'page_selection'
require_relative 'page_filter'
require_relative 'page_roles'
require_relative 'lines'
require_relative 'notes'
require_relative 'endnotes'
require_relative 'blocks'
require_relative 'repeats'
require_relative '../translator'

module Audiobook
  # Represents an intermediate structured manuscript that can be saved as YAML.
  class Book
    LANGUAGE_SAMPLE_PAGES = 5
    SAMPLE_SCAN_PAGES     = 40
    TOC_LEADER            = /(?:\.{4,}|\s{3,})\s*\d{1,4}\s*\z/
    MAX_STRUCTURED_BYTES = ENV.fetch('MAX_STRUCTURED_DOCUMENT_BYTES', 20 * 1024 * 1024).to_i
    CHINESE_MAX_SENTENCE_CHARS = 30

    attr_reader :data, :metadata, :pages, :translated, :translated_base, :author_gender, :font_roles

    def title    = field(:title)
    def author   = field(:author)
    def language = (@lang.presence || field(:language) || 'en').to_s

    # Alias for backward compatibility
    def items
      pages.flat_map(&:items)
    end

    def self.from_input(input_path, opts: nil, stl: nil, translate: true)
      return parse_url_kindle(input_path, opts: opts, stl: stl, translate: translate) if url_kindle?(input_path)

      format = SourceFormats.format_for_path(input_path)
      return from_yaml(input_path, opts: opts, stl: stl, translate: translate) if format&.dig(:loader) == :yaml

      new(data: parse_input(input_path, format, opts: opts, stl: stl), opts: opts, stl: stl, translate: translate)
    end

    def self.detect_language(input_path, opts: nil, stl: nil)
      lang = source_language(opts)
      return lang if lang

      format = SourceFormats.format_for_path(input_path)
      data = if format&.dig(:loader) == :yaml
        SymMash.new(load_yaml(input_path))
      else
        parse_input(input_path, format, opts: opts, stl: stl)
      end

      obj = allocate
      obj.instance_variable_set(:@data, data)
      obj.instance_variable_set(:@metadata, data.metadata || SymMash.new)
      obj.instance_variable_set(:@opts, opts || SymMash.new)
      obj.instance_variable_set(:@stl, stl)
      obj.send(:detect_publication!)
      obj.metadata.language || 'en'
    end

    def self.parse_input(input_path, format = SourceFormats.format_for_path(input_path), opts: nil, stl: nil)
      parser = format&.fetch(:parser, nil) || :parse_fallback_ocr
      public_send(parser, input_path, stl: stl, opts: opts)
    end

    def self.lang_code(value) = value.to_s.strip.presence

    # alang = source override. slang/lang = speech target.
    # lang= expands to matching alang+slang; that pair is a target, not a source.
    def self.source_language(opts)
      alang = lang_code(opts&.alang)
      alang unless alang && alang == speech_language(opts)
    end

    def self.speech_language(opts) = lang_code(opts&.slang) || lang_code(opts&.lang)

    def self.translate_sentences(sentences, from:, to:)
      sentences.group_by { |sent| sent.language.presence || from }.each do |source, group|
        texts = Array(Translator.translate(group.map(&:text), from: source, to: to))
        group.zip(texts).each do |sent, text|
          sent.text     = text
          sent.language = to
        end
      end
    end

    def self.url_kindle?(input_path)
      s = input_path.to_s
      return false unless s.start_with?('http')
      host = URI.parse(s).host rescue nil
      Audiobook::Parsers::Kindle::READ_HOSTS.include?(host)
    end

    def self.parse_url_kindle(input_path, opts: nil, stl: nil, translate: true)
      stl&.update 'Capturing Kindle reader via browser...'
      data = Parsers::Kindle.parse(input_path, stl: stl, opts: opts)
      pdf_path = data.content&.pdf || data.pdf
      if pdf_path && File.exist?(pdf_path)
        stl&.update 'Analyzing document and extracting text...'
        parsed = Parsers::Pdf.parse(pdf_path, stl: stl, opts: opts)
        # Preserve the compiled PDF path in metadata for downstream upload
        begin
          parsed = SymMash.wrap(parsed)
          md = parsed.metadata || SymMash.new
          md.kindle_pdf = pdf_path
          parsed.metadata = md
        rescue => e
          STDERR.puts "[KINDLE] metadata assign failed: #{e.class}: #{e.message}"
        end
        return new(data: parsed, opts: opts, stl: stl, translate: translate)
      end
      new(data: data, opts: opts, stl: stl, translate: translate)
    end

    def self.parse_json(json_path, stl: nil, opts: nil)
      SymMash.new(JSON.parse(read_structured(json_path)))
    end

    def self.parse_pdf(pdf_path, stl: nil, opts: nil)   = parse_document(Parsers::Pdf, pdf_path, stl: stl, opts: opts)
    def self.parse_epub(epub_path, stl: nil, opts: nil) = parse_document(Parsers::Epub, epub_path, stl: stl, opts: opts)

    def self.parse_document(parser, path, stl:, opts:)
      stl&.update 'Analyzing document and extracting text...'
      data = parser.parse(path, stl: stl, opts: opts)
      stl&.update 'Structuring content and processing images...'
      data
    end

    def self.parse_html(html_path, stl: nil, opts: nil)
      stl&.update 'Analyzing HTML document'
      Parsers::Html.parse(html_path, stl: stl, opts: opts)
    end

    def self.parse_txt(txt_path, stl: nil, opts: nil)
      stl&.update 'Analyzing text document'
      Parsers::Txt.parse(txt_path, stl: stl, opts: opts)
    end

    def self.parse_fallback_ocr(path, stl: nil, opts: nil)
      Ocr.transcribe(path, opts: opts, stl: stl)
    end

    def self.from_yaml(yaml_path, opts: nil, stl: nil, translate: true)
      data = SymMash.new(load_yaml(yaml_path))
      # Support both new format (no metadata) and legacy format (with metadata)
      metadata = data.metadata || SymMash.new
      metadata.language ||= data.language
      metadata.language ||= source_language(opts)
      
      # Parse pages or legacy items
      pages = if data.pages
        (data.pages || []).map do |page_data|
          page_info = (page_data.is_a?(Hash) ? SymMash.new(page_data) : page_data).page || SymMash.new
          number = page_info.number || 0
          items = (page_info.items || []).map { |item| parse_item(item.is_a?(Hash) ? SymMash.new(item) : item) }.compact
          Page.new(number, items)
        end
      else
        # Legacy format: single page with all items
        items = (data.items || []).map { |item| parse_item(item.is_a?(Hash) ? SymMash.new(item) : item) }.compact
        [Page.new(1, items)]
      end
      
      obj = allocate
      obj.instance_variable_set(:@data, nil)
      obj.instance_variable_set(:@metadata, metadata)
      obj.instance_variable_set(:@opts, opts || SymMash.new)
      obj.instance_variable_set(:@stl, stl)
      obj.instance_variable_set(:@lang, metadata.language || 'en')
      obj.instance_variable_set(:@pages, pages)
      obj.instance_variable_set(:@font_roles, FontRoles.from_h(data.font_roles)) if data.font_roles
      obj.send(:finish_pages!, translate: translate)
      obj
    end

    def self.load_yaml(path)
      YAML.safe_load(read_structured(path), permitted_classes: [Date, Time], aliases: false) || {}
    end

    def self.read_structured(path)
      raise ArgumentError, 'structured document is too large' if File.size(path) > MAX_STRUCTURED_BYTES
      File.binread(path)
    end

    def self.parse_item(item)
      item = SymMash.wrap(item)
      # Item is a hash with single key indicating type
      if item.heading
        heading = Heading.new(item.heading.text, language: item.heading.language) if Sentence.speakable_text?(item.heading.text)
        apply_item_style(heading, item.heading)
      elsif item.section
        section = item.section
        parsed = Section.new(section.text, level: section.level || 1, language: section.language) if Sentence.speakable_text?(section.text)
        apply_item_style(parsed, section)
      elsif item.reference
        ref_info = item.reference
        sentences = Sentence.build_all(ref_info.sentences)
        Reference.new(ref_info.id, sentences)
      elsif item.image
        img = Image.allocate
        img.instance_variable_set(:@path, item.image.path || '')
        sentences = Sentence.build_all(item.image.sentences)
        img.instance_variable_set(:@sentences, sentences)
        img
      elsif item.paragraph
        sentences = (item.paragraph.sentences || []).map do |s|
          s = SymMash.wrap(s)
          sent = Sentence.build(s)
          next unless sent
          if s.references
            sent.references = s.references.map do |r|
              ref_info = r.reference || r
              ref_info = SymMash.wrap(ref_info)
              ref_sents = Sentence.build_all(ref_info.sentences)
              Reference.new(ref_info.id, ref_sents)
            end
          end
          sent
        end.compact
        Paragraph.new(sentences) unless sentences.empty?
      else
        # Legacy format fallback with 'type' field
        type = item.type
        case type
        when 'Heading'
          Heading.new(item.text, language: item.language)
        when 'Image'
          img = Image.allocate
          img.instance_variable_set(:@path, item.path || '')
          sentences = Sentence.build_all(item.sentences)
          img.instance_variable_set(:@sentences, sentences)
          img
        else
          sentences = Sentence.build_all(item.sentences)
          Paragraph.new(sentences) unless sentences.empty?
        end
      end
    end

    def self.apply_item_style(item, data)
      FontRoles.copy_style(item, data) if item && data
      item.role = data.role.to_s.to_sym if item && data.role
      item
    end

    def initialize(data:, opts: nil, stl: nil, translate: true)
      @data = data
      @metadata = @data.metadata || SymMash.new
      @opts = opts || SymMash.new
      @stl = stl
      @metadata.language ||= self.class.source_language(@opts)
      
      detect_publication!
      @lang = @metadata.language || 'en'

      # Handle new line-based format or legacy paragraph format
      if @data.content&.lines
        @pages = pages_from_lines(@data.content.lines, @data.content.images || [])
      else
        @pages = pages_from_paragraphs
      end

      finish_pages!(translate: translate)
    end

    # Write YAML file following class hierarchy representation
    def write(yaml_path)
      book_hash = { 'language' => language, 'pages' => pages.map(&:to_h) }
      book_hash['font_roles'] = font_roles.to_h if font_roles
      outline_data = outline
      book_hash['outline'] = outline_data if outline_data.any?
      book_hash = deep_to_h(book_hash)
      begin
        File.write(yaml_path, YAML.dump(book_hash, line_width: -1))
      rescue ArgumentError
        File.write(yaml_path, YAML.dump(book_hash))
      end
    end

    def outline
      tree = []
      current = nil
      pages.each do |page|
        page.items.grep(Heading).each do |item|
          entry = outline_entry(item, page)
          if chapter_entry?(item)
            current = entry.merge('headings' => [])
            tree << current
          elsif current
            current['headings'] << entry
          else
            tree << entry
          end
        end
      end
      tree.each { |entry| entry.delete('headings') if entry['headings']&.empty? }
      tree
    end

    def outline_entry(item, page)
      entry = { 'text' => item.text, 'page' => page.number }
      entry['role'] = item.role.to_s if item.role
      entry['level'] = item.level if item.is_a?(Section)
      entry['font_size'] = item.font_size if item.font_size
      entry['alignment'] = item.alignment.to_s if item.alignment
      entry['bold'] = item.bold unless item.bold.nil?
      entry['italic'] = item.italic unless item.italic.nil?
      entry['color'] = item.color if item.color
      entry['font_name'] = item.font_name if item.font_name
      entry
    end

    def chapter_entry?(item)
      item.role.to_s == 'chapter' || (item.is_a?(Section) && item.level == 1 && item.role.to_s != 'title')
    end

    def deep_to_h(obj)
      case obj
      when SymMash
        obj.to_h.transform_values { |v| deep_to_h(v) }
      when Hash
        obj.transform_values { |v| deep_to_h(v) }
      when Array
        obj.map { |v| deep_to_h(v) }
      else
        obj
      end
    end

    def thumb(dir:, base:)
      cover_for_thumb&.thumbnail(dir: dir, base: base)
    end

    private

    def detect_publication!
      return if @publication_detected

      @publication_detected = true
      if @opts.html_title.present?
        @author_gender ||= 'male'
        return
      end

      sample = publication_sample
      return if sample.blank?

      @stl&.update 'Detecting book metadata'
      info = Language.book_metadata(Language.book_input(metadata, sample, filename: publication_filename))
      @metadata.title    = info['title']  if info['title'].present?
      @metadata.author   = info['author'] if info['author'].present?
      @metadata.language = info['lang']   if field(:language).blank? && info['lang'].to_s.match?(/\A[a-z]{2}\z/)
      @author_gender     = info['gender'].presence || 'male'
    end

    def cover_for_thumb
      metadata.cover.presence || cover_from_source
    end

    def cover_from_source
      path = field(:source_path)
      return unless path && File.file?(path.to_s)

      Cover.from_page(path, SymMash.new(number: 1, width: field(:page_width).to_f, height: field(:page_height).to_f))
    end

    def extract_sample_text
      ordered_sample = extract_ordered_content_sample
      return ordered_sample if ordered_sample.any?

      return [SymMash.new(text: @data.content.text)] if @data.content&.text
      return [SymMash.new(text: @data.text)] if @data.text
      []
    end

    def extract_ordered_content_sample
      return [] unless @data.content

      text_items = language_text_items
      image_items = Array(@data.content.images).map { |img| normalize_symmash(img) }
      return [] if text_items.empty? && image_items.empty?

      sample_pages(text_items, image_items).flat_map do |page|
        texts_for_page(text_items, page) + image_texts_for_page(image_items, page)
      end.map { |text| SymMash.new(text: text) }
    end

    def language_text_items
      lines = Array(@data.content.lines).map { |item| normalize_symmash(item) }
      return lines if lines.any?

      Array(@data.content.paragraphs).map { |item| normalize_symmash(item) }
    end

    def sample_pages(text_items, image_items)
      pages = (text_items.map { |item| page_for(item) } + image_items.map { |item| page_for(item) })
        .compact.uniq.sort_by(&:to_i)
      texts_by_page = pages.first(SAMPLE_SCAN_PAGES).index_with { |page| texts_for_page(text_items, page) }
      self.class.select_publication_pages(pages, texts_by_page)
    end

    def self.select_publication_pages(pages, texts_by_page)
      ranked = pages.first(SAMPLE_SCAN_PAGES)
      chosen = ranked.reject { |page| toc_like_page?(texts_by_page[page]) }
      (chosen.presence || ranked).first(LANGUAGE_SAMPLE_PAGES)
    end

    def self.toc_like_page?(texts)
      lines   = Array(texts).map { |text| text.to_s.strip }.reject(&:empty?)
      return false if lines.size < 5

      leaders = lines.count { |line| line.match?(TOC_LEADER) }
      leaders >= 5 && leaders >= (lines.size * 0.3)
    end

    def publication_filename
      @opts&.source_base.presence || field(:source_name)
    end

    def texts_for_page(items, page)
      items.select { |item| page_for(item) == page }
        .filter_map { |item| item.text.to_s.strip.presence }
    end

    def image_texts_for_page(items, page)
      items.select { |item| page_for(item) == page }
        .filter_map { |item| ocr_text_for_language_sample(item).strip.presence }
    end

    def ocr_text_for_language_sample(image_data)
      return image_data.text.to_s if image_data.text.to_s.strip.present?
      return '' unless image_data.path

      OcrText.transcribe(image_data.path, stl: @stl, opts: @opts)
    end

    def page_for(item)
      item.page || Array(item.page_numbers).first || 1
    end

    def normalize_symmash(obj)
      SymMash.wrap(obj)
    end

    # Build pages from Line objects (new format with font metadata)
    def pages_from_lines(lines_data, images_data = [])
      roles    = PageRoles.from_lines(lines_data) unless include_all?
      endnotes = roles ? Endnotes.from_lines(lines_data) : Endnotes.none
      lines    = Lines.build(narrated(lines_data, roles, endnotes))

      @font_roles = FontRoles.from_lines(lines)
      items = FontRoles.use(@font_roles) do
        Paragraph.discover_from_lines(lines, max_sentence_chars: max_sentence_chars)
      end.map { |entry| SymMash.new(entry) }

      build_pages(Repeats.strip(Blocks.merge(Notes.attach(items, endnotes: endnotes))), images_data)
    end

    def narrated(lines_data, roles, endnotes)
      return lines_data unless roles

      PageFilter.narrated(lines_data, roles: roles, selected_pages: @metadata.selected_pages,
                          skip_pages: endnotes.pages)
    end

    def max_sentence_chars
      @lang == 'zh' ? CHINESE_MAX_SENTENCE_CHARS : Paragraph::Factory::MAX_SENTENCE_CHARS
    end

    def build_pages(items_with_pages, images_data)
      pages_hash = group_items_by_page(items_with_pages)
      add_images(pages_hash, images_data)
      # An empty page still takes its turn, so the narration keeps the book's numbering.
      page_numbers&.each { |page_num| pages_hash[page_num] ||= [] }

      pages_hash.sort.map { |page_num, items| Page.new(page_num, items) }
    end

    def page_numbers
      total = @metadata.page_count
      @metadata.selected_pages || (1.upto(total) if total)
    end

    # An image can share a page with text, and OCR happens as the Image is built.
    def add_images(pages_hash, images_data)
      total = @metadata.page_count
      added = Set.new
      images_data.each do |img_data|
        img_data = SymMash.wrap(img_data)
        next unless img_data.path && img_data.page
        next unless added.add?([img_data.page, img_data.path])

        context = SymMash.new(current: img_data.page, total: total) if total
        pages_hash[img_data.page] ||= []
        pages_hash[img_data.page] << Image.new(
          img_data.path, stl: @stl, page_context: context, text: img_data.text, opts: ocr_opts
        )
      end
    end

    def ocr_opts
      opts = SymMash.new(@opts || {})
      opts.lang ||= @metadata.language if @metadata.language
      opts
    end

    def group_items_by_page(items_with_pages)
      items_with_pages.each_with_object(SymMash.new { |h, k| h[k] = [] }) do |item_data, h|
        h[item_data.page] << item_data.item
      end
    end

    def include_all?
      !!(@opts&.includeall || @data&.opts&.includeall || translation_needed?)
    end

    def finish_pages!(translate: true)
      select_pages!
      filter_repeated_page_boundaries! unless include_all?
      detect_publication!
      translate! if translate && translation_needed?
    end

    def select_pages!
      selected_pages = PageSelection.parse(@opts&.pages)
      return unless selected_pages

      available_pages = pages.map(&:number)
      missing_pages   = selected_pages - available_pages
      raise ArgumentError, "pages not found: #{missing_pages.join(', ')}" if missing_pages.any?

      @pages = pages.select { |page| selected_pages.include?(page.number) }
    end

    # A book assembled from lines has its running heads and feet removed while they are still
    # lines, where their repetition and their place on the page can both be read. One loaded
    # from YAML arrives already assembled, and their repetition is all that is left to go on.
    def filter_repeated_page_boundaries!
      return if pages.size < 3

      normalized_counts = Hash.new(0)
      exact_counts      = Hash.new(0)
      page_candidates   = {}

      pages.each do |page|
        candidates = [page.items.first, page.items.last].compact.uniq.flat_map { |item| direct_sentences(item) }
        page_candidates[page] = candidates
        candidates.map { |sentence| TextHelpers.comparable_key(sentence.text) }.uniq.each { |text| normalized_counts[text] += 1 }
        candidates.map { |sentence| TextHelpers.comparable(sentence.text) }.uniq.each { |text| exact_counts[text] += 1 }
      end

      threshold = [(pages.size * 0.3).ceil, 3].max
      repeated_normalized = normalized_counts.select { |_, count| count >= threshold }.keys.to_set
      repeated_exact      = exact_counts.select { |_, count| count >= threshold }.keys.to_set
      return if repeated_normalized.empty?

      pages.each do |page|
        boundary_sentences = page_candidates.fetch(page).to_set
        page.items.reject! do |item|
          remove_item = prune_repeated_sentences!(item, boundary_sentences, repeated_normalized, repeated_exact)
          remove_item || (item.is_a?(Paragraph) && item.empty?)
        end
      end
    end

    def direct_sentences(item)
      item.is_a?(Sentence) ? [item] : Array(item.is_a?(Paragraph) ? item.sentences : nil)
    end

    def prune_repeated_sentences!(item, boundary_sentences, repeated_normalized, repeated_exact)
      if item.is_a?(Sentence)
        prune_repeated_references!(item, repeated_exact)
        return repeated_sentence?(item, boundary_sentences, repeated_normalized, repeated_exact)
      end
      return false unless item.is_a?(Paragraph)

      item.sentences.reject! do |sentence|
        prune_repeated_references!(sentence, repeated_exact)
        repeated_sentence?(sentence, boundary_sentences, repeated_normalized, repeated_exact)
      end
      false
    end

    def prune_repeated_references!(sentence, repeated_exact)
      sentence.references.each do |reference|
        reference.sentences.reject! do |referenced|
          prune_repeated_references!(referenced, repeated_exact)
          repeated_exact_sentence?(referenced, repeated_exact)
        end
      end
    end

    def repeated_sentence?(sentence, boundary_sentences, repeated_normalized, repeated_exact)
      repeated_exact_sentence?(sentence, repeated_exact) ||
        (boundary_sentences.include?(sentence) && repeated_normalized.include?(TextHelpers.comparable_key(sentence.text)))
    end

    def repeated_exact_sentence?(sentence, repeated_exact)
      text = TextHelpers.comparable(sentence.text)
      repeated_exact.any? { |candidate| text == candidate || (candidate.length >= 40 && text.include?(candidate)) }
    end

    # Build pages from legacy paragraph format
    def pages_from_paragraphs
      paras_with_pages = extract_paragraphs_with_pages
      pages_hash = SymMash.new { |h, k| h[k] = [] }
      paras_with_pages.each do |para_data|
        page_nums = para_data[:page_numbers] || [1]
        page_num = page_nums.first
        pages_hash[page_num] << para_data[:text]
      end
      
      pages_hash.to_a.sort.map do |page_num, texts|
        items = Paragraph.discover(texts)
        Page.new(page_num, items)
      end
    end

    # ---------- extraction helpers ----------
    def extract_paragraphs_with_pages
      paras = @data.content&.paragraphs || []
      unless paras.empty?
        return paras.map { |p| SymMash.new(text: p['text'] || p[:text] || p.text, page_numbers: p['page_numbers'] || p[:page_numbers] || p.page_numbers || [1]) }
      end

      @stl&.update 'No paragraphs found, checking alternative text'
      alt = find_alternative_text
      return [] unless alt&.strip&.length&.positive?
      [SymMash.new(text: alt, page_numbers: [1])]
    end

    def find_alternative_text
      return @data.text if @data.text
      return @data.content&.text if @data.content&.text
      return extract_pages_text if @data.content&.pages
      return extract_headers_footers if @data.metadata&.pages
    end

    def extract_pages_text
      pages_text = @data.content.pages.map { |page| page['text'] || page[:text] || page.text }.compact.join(' ')
      pages_text.empty? ? nil : pages_text
    end

    def extract_headers_footers
      pages_text = []
      prev_headers = Set.new
      prev_footers = Set.new

      @data.metadata.pages.each do |page|
        pages_text << process_header(page, prev_headers)
        pages_text << process_footer(page, prev_footers)
      end

      pages_text.compact.uniq.join(' ').then { |text| text.empty? ? nil : text }
    end

    def process_header(page, prev_headers)
      page = SymMash.wrap(page)
      return unless page.header&.strip&.length&.positive?
      header_text = page.header.strip
      result = header_text unless prev_headers.include?(header_text)
      prev_headers << header_text
      result
    end

    def process_footer(page, prev_footers)
      page = SymMash.wrap(page)
      return unless page.footer&.strip&.length&.positive?
      footer_text = page.footer.strip
      result = footer_text unless prev_footers.include?(footer_text)
      prev_footers << footer_text
      result
    end



    public

    def speech_language = self.class.speech_language(@opts)

    def translation_needed?
      (target = speech_language) && target != @lang.to_s
    end

    def mark_translated!(target)
      @lang = @metadata.language = target
      @translated = true
    end

    def translate!
      target = speech_language
      pending = @pages.flat_map(&:all_sentences).reject { |sent| sent.language.to_s == target.to_s }
      if pending.any?
        @stl&.update 'Translating pages'
        self.class.translate_sentences(pending, from: @lang, to: target)
      end
      translate_names!(from: @lang, to: target)
      mark_translated!(target)
    end

    def translate_names!(from:, to:)
      names = [title, author, @opts&.source_base.presence].compact.uniq
      return if names.empty?

      @stl&.update 'Translating title'
      names.zip(Array(Translator.translate(names, from: from, to: to))).each do |orig, text|
        apply_translated_name(orig, text)
      end
    end

    def apply_translated_name(orig, text)
      text = text.to_s.gsub(/[\/\\\0]/, ' ').gsub(/\s+/, ' ').strip.presence || orig
      @metadata.title    = text if orig == title
      @metadata.author   = text if orig == author
      @translated_base   = text if @opts&.source_base.to_s == orig
    end

    def publication_sample
      if instance_variable_defined?(:@pages) && @pages
        pages.first(LANGUAGE_SAMPLE_PAGES).flat_map(&:all_sentences).map(&:text).join("\n")
      else
        extract_sample_text.map { |para| para[:text] || para.text }.join("\n")
      end
    end

    def field(key)
      metadata[key].presence || metadata[key.to_s].presence
    end
    private :field
  end
end
