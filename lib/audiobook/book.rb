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
require_relative '../translator'

module Audiobook
  # Represents an intermediate structured manuscript that can be saved as YAML.
  class Book
    LANGUAGE_SAMPLE_PAGES = 5
    SAMPLE_SCAN_PAGES     = 40
    TOC_LEADER            = /(?:\.{4,}|\s{3,})\s*\d{1,4}\s*\z/
    MAX_STRUCTURED_BYTES = ENV.fetch('MAX_STRUCTURED_DOCUMENT_BYTES', 20 * 1024 * 1024).to_i
    CHINESE_MAX_SENTENCE_CHARS = 30

    attr_reader :metadata, :pages, :translated, :translated_base, :author_gender, :font_roles

    def title    = field(:title)
    def author   = field(:author)
    def language = (@lang.presence || field(:language) || 'en').to_s

    # Alias for backward compatibility
    def items
      pages.flat_map(&:items)
    end

    def paragraphs
      items
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
          parsed = SymMash.new(parsed) unless parsed.is_a?(SymMash)
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
      item = SymMash.new(item) unless item.is_a?(SymMash)
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
          s = SymMash.new(s) unless s.is_a?(SymMash)
          sent = Sentence.build(s)
          next unless sent
          if s.references
            sent.references = s.references.map do |r|
              ref_info = r.reference || r
              ref_info = SymMash.new(ref_info) unless ref_info.is_a?(SymMash)
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
      item.role = data.role.to_s.to_sym if item.respond_to?(:role=) && data.respond_to?(:role) && data.role
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
      entry['role'] = item.role.to_s if item.respond_to?(:role) && item.role
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
      obj.is_a?(SymMash) ? obj : SymMash.new(obj)
    end

    # Build pages from Line objects (new format with font metadata)
    def pages_from_lines(lines_data, images_data = [])
      filtered_lines = include_all? ? lines_data : filter_headers_footers(lines_data)
      
      # Create Line objects
      lines = filtered_lines.map do |l|
        l = SymMash.new(l) unless l.is_a?(SymMash)
        Line.new(
          l.text,
          font_size: l.font_size,
          y_position: l.y,
          page_number: l.page,
          x_position: l.x,
          x_max: l.x_max,
          page_width: l.page_width,
          top_spacing: l.top_spacing,
          bottom_spacing: l.bottom_spacing,
          section_level: l.section_level || l.section_level,
          language: l.language,
          alignment: l.alignment,
          bold: l.bold,
          italic: l.italic,
          color: l.color,
          font_name: l.font_name
        )
      end.reject(&:empty?)

      @font_roles = FontRoles.from_lines(lines)
      items_with_pages = FontRoles.use(@font_roles) do
        Paragraph.discover_from_lines(
          lines,
          max_sentence_chars: @lang == 'zh' ? CHINESE_MAX_SENTENCE_CHARS : Paragraph::Factory::MAX_SENTENCE_CHARS
        )
      end.map { |e| SymMash.new(e) }

      # Pre-compute body font per page as the most frequent paragraph font size
      body_font_by_page = compute_body_font_by_page(items_with_pages)

      # Track which pages already have images to avoid duplicates
      images_added = Set.new

      # Attach inline reference markers and collect footnote paragraphs
      # Strategy:
        # - Detect numeric-only paragraphs as reference markers (e.g., "5") on a page
        # - Attach a Reference(id: "5") to the last sentence of the previous paragraph on same page
        # - Move any paragraphs whose first sentence starts with that number (e.g., "5 Lorem ...")
        #   into the Reference object and remove them from the items list
        # - If subsequent paragraphs (same font size as footnotes) appear before the next marker,
        #   attach them to the last reference on that page (supports multi-paragraph notes)
      ref_map = SymMash.new { |h, k| h[k] = SymMash.new } # { page => { '5' => Reference } }
      pending_refs = SymMash.new { |h, k| h[k] = [] }
      # For markers that appear between lines inside a paragraph (e.g., after a word),
      # when the previous paragraph's last sentence doesn't end with punctuation yet,
      # defer attaching and bind to the first sentence of the next paragraph on the same page.
      attach_to_next = SymMash.new { |h, k| h[k] = [] }
      last_ref_by_page = {}
      last_para_by_page = {}

      # Pre-pass: detect inline markers appended to words/punctuation, e.g., "Troyes.1" or "Eschenbach2"
      # Remove the numeric token from the sentence and attach the reference to this sentence
      items_with_pages.each do |entry|
        item = entry.item
        next unless item.is_a?(Paragraph)
        page_num = entry.page
        item.sentences.each do |sent|
          new_text, ids = TextHelpers.strip_inline_markers(sent.text)
          sent.text = new_text if new_text != sent.text
          if ids.any?
            ids.each do |id|
              ref = ref_map[page_num][id] ||= Reference.new(id)
              sent.add_reference(ref)
              last_ref_by_page[page_num] = ref
            end
          end
        end
      end

      marker_id_for = method(:marker_ids_for)

      # First pass: identify markers and attach to previous paragraph's last sentence
      processed = []
      items_with_pages.each do |entry|
        item = entry.item
        page_num = entry.page

        item_font = entry.font_size

        if (ref_ids = marker_id_for.call(item)) && !ref_ids.empty?
          # Attach each marker id to the last sentence of the previous paragraph
          ref_ids.each do |ref_id|
            if ref_map[page_num].key?(ref_id) && body_font_by_page[page_num] && item_font && item_font < body_font_by_page[page_num].to_f - 1.0
              next
            end
            ref = ref_map[page_num][ref_id] ||= Reference.new(ref_id)

            if (prev_para = last_para_by_page[page_num]) && prev_para.sentences.any?
              last_sentence = prev_para.sentences.last
              if last_sentence.text.to_s.strip.match?(/[.!?…]"?\)?$/)
                ref = last_sentence.add_reference(ref) || ref
                ref_map[page_num][ref_id] = ref
                last_ref_by_page[page_num] = ref
              else
                attach_to_next[page_num] << ref
              end
            else
              attach_to_next[page_num] << ref
            end

            pending_refs[page_num] << SymMash.new(ref: ref, min_idx: processed.size)
          end
          next
        end

        if item.is_a?(Paragraph)
          # If there were deferred refs waiting for the next paragraph, attach/distribute now
          if attach_to_next[page_num].any?
            refs = attach_to_next[page_num]
            sentences = item.sentences
            if sentences.any?
              # Attach the first id to the first sentence
              sentences.first.add_reference(refs.shift)
              # Distribute the rest across subsequent sentences
              sentences.drop(1).each do |s|
                break if refs.empty?
                s.add_reference(refs.shift)
              end
              # If still remaining, attach to the last sentence
              if refs.any?
                refs.each { |r| sentences.last.add_reference(r) }
              end
              last_ref_by_page[page_num] = sentences.last.references&.last || last_ref_by_page[page_num]
            end
            attach_to_next[page_num].clear
          end
          last_para_by_page[page_num] = item
        end
        processed << entry
      end

      # Second pass: move footnote paragraphs into existing references on same page
      items_with_pages = []
      processed.each_with_index do |entry, idx|
        item = entry.item
        page_num = entry.page
        queue = pending_refs[page_num]
        if item.is_a?(Paragraph) && item.sentences.any?
          first_text = item.sentences.first.text
          # If paragraph starts with multiple markers like "1 2 Texto...", drop the first id and keep text
          leading_match = first_text.match(/^(\d+)[\)\.]?\s+(.*)$/)
          if leading_match
            lead_id = leading_match[1]
            ref = ref_map[page_num][lead_id]
            unless ref
              ref = Reference.new(lead_id)
              if (prev_para = last_para_by_page[page_num]) && prev_para.sentences.any?
                last_sentence = prev_para.sentences.last
                ref = last_sentence.add_reference(ref) || ref
              end
              ref_map[page_num][lead_id] = ref
            end
            if ref
              if (entry_info = queue.find { |info| info.ref.equal?(ref) })
                entry_info.min_idx = idx + 1
              end
              item.sentences.first.text = leading_match[2]
              ref.add_sentences(item.sentences)
              pending_refs[page_num].reject! { |info| info.ref.equal?(ref) && info.min_idx <= idx }
              last_ref_by_page[page_num] = ref
              next
            end
          elsif (info = queue.find { |data| data.min_idx <= idx })
            body_font = body_font_by_page[page_num]
            line_font = entry.font_size
            if body_font && line_font && line_font < body_font.to_f - 1.0
              ref = info.ref
              info.min_idx = idx + 1
              ref.add_sentences(item.sentences)
              last_ref_by_page[page_num] = ref
              pending_refs[page_num].delete(info)
              next
            end
          else
            ref = last_ref_by_page[page_num]
            body_font = body_font_by_page[page_num]
            line_font = entry.font_size
            if ref && (queue.nil? || queue.empty?) && body_font && line_font && line_font < body_font.to_f - 1.0
              ref.add_sentences(item.sentences)
              next
            end
          end
        end
        items_with_pages << entry
      end

      # Merge paragraphs split across pages or within a page when it looks like a continuation
      merged_items = []
      items_with_pages.each do |entry|
        item = entry.item
        if item.is_a?(Paragraph) && item.sentences.any? && merged_items.any?
          prev_entry = merged_items[-1]
          prev_item = prev_entry.item
          if prev_item.is_a?(Paragraph)
            page_changed = entry.page > prev_entry.page
            font_close = entry.font_size && prev_entry.font_size ? (entry.font_size - prev_entry.font_size).abs < 0.6 : true
            same_language = prev_item.sentences.last&.language == item.sentences.first&.language
            if font_close && same_language
              last_text = prev_item.sentences.last&.text.to_s.strip
              first_text = item.sentences.first&.text.to_s.strip
              looks_unfinished = last_text !~ /[.!?…]"?\)?$/
              looks_continuation = first_text.match?(/\A[[:lower:]]/)
              if (!last_text.empty? && looks_unfinished) || (!first_text.empty? && looks_continuation)
                if looks_unfinished && !first_text.empty?
                  # Join first sentence text and references into the previous last sentence
                  prev_last = prev_item.sentences.last
                  next_first = item.sentences.first
                  if prev_last && next_first
                    merged_text = [prev_last.text, next_first.text].join(' ').gsub(/\s+/, ' ').strip
                    prev_last.text = merged_text
                    Array(next_first.references).each { |r| prev_last.add_reference(r) }
                    # append remaining sentences from the next paragraph
                    prev_item.sentences.concat(item.sentences.drop(1))
                  else
                    prev_item.sentences.concat(item.sentences)
                  end
                else
                  prev_item.sentences.concat(item.sentences)
                end
                next
              end
            end
          end
        end
        merged_items << entry
      end
      items_with_pages = merged_items
 
      # Group items by their page number
      pages_hash = group_items_by_page(items_with_pages)
      
      # Add Image objects for pages with images (can coexist with text on same page)
      total_pages = @metadata.page_count
      images_data.each do |img_data|
        img_data = SymMash.new(img_data) unless img_data.is_a?(SymMash)
        page_num = img_data.page
        path = img_data.path
        next unless path && page_num
        next if images_added.include?([page_num, path])

        page_context = total_pages ? SymMash.new(current: page_num, total: total_pages) : nil
        # Image will handle rasterization and OCR in its initializer
        pages_hash[page_num] ||= []
        pages_hash[page_num] << Image.new(path, stl: @stl, page_context: page_context, text: img_data.text, opts: ocr_opts)
        images_added << [page_num, path]
      end

      if total_pages
        page_numbers = @metadata.selected_pages || 1.upto(total_pages)
        page_numbers.each { |page_num| pages_hash[page_num] ||= [] }
      end
      
      # Create Page objects
      pages_hash.sort.map { |page_num, items| Page.new(page_num, items) }
    end

    def compute_body_font_by_page(items_with_pages)
      font_counts_by_page = SymMash.new { |h, k| h[k] = SymMash.new }
      items_with_pages.each do |entry|
        item = entry.item
        next unless item.is_a?(Paragraph)
        fs = entry.font_size
        next unless fs
        font_counts_by_page[entry.page][(fs.to_f * 10).round / 10.0] ||= 0
        font_counts_by_page[entry.page][(fs.to_f * 10).round / 10.0] += 1
      end
      font_counts_by_page.each_with_object(SymMash.new) do |(page, counts), acc|
        acc[page] = counts.to_a.max_by { |_, c| c }&.first
      end
    end

    def ocr_opts
      opts = SymMash.new(@opts || {})
      opts.lang ||= @metadata.language if @metadata.language
      opts
    end

    def marker_ids_for(item)
      raw = case item
      when Paragraph
        return nil unless item.sentences.size == 1
        item.sentences.first.text
      when Heading
        item.text
      end
      value = raw.to_s.strip
      value.scan(/\d+/) if value.match?(/\A\d+[\)\.\]]*(?:\s+\d+[\)\.\]]*)*\z/)
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

    def filter_repeated_page_boundaries!
      return if pages.size < 3

      normalized_counts = Hash.new(0)
      exact_counts      = Hash.new(0)
      page_candidates   = {}

      pages.each do |page|
        candidates = [page.items.first, page.items.last].compact.uniq.flat_map { |item| direct_sentences(item) }
        page_candidates[page] = candidates
        candidates.map { |sentence| normalize_boundary_text(sentence.text) }.uniq.each { |text| normalized_counts[text] += 1 }
        candidates.map { |sentence| exact_boundary_text(sentence.text) }.uniq.each { |text| exact_counts[text] += 1 }
      end

      threshold = [(pages.size * 0.3).ceil, 3].max
      repeated_normalized = normalized_counts.select { |_, count| count >= threshold }.keys.to_set
      repeated_exact      = exact_counts.select { |_, count| count >= threshold }.keys.to_set
      return if repeated_normalized.empty?

      pages.each do |page|
        boundary_sentences = page_candidates.fetch(page).to_set
        page.items.reject! do |item|
          remove_item = prune_repeated_sentences!(item, boundary_sentences, repeated_normalized, repeated_exact)
          remove_item || (item.respond_to?(:empty?) && item.empty?)
        end
      end
    end

    def direct_sentences(item)
      item.is_a?(Sentence) ? [item] : (item.respond_to?(:sentences) ? item.sentences : [])
    end

    def prune_repeated_sentences!(item, boundary_sentences, repeated_normalized, repeated_exact)
      if item.is_a?(Sentence)
        prune_repeated_references!(item, repeated_exact)
        return repeated_sentence?(item, boundary_sentences, repeated_normalized, repeated_exact)
      end
      return false unless item.respond_to?(:sentences)

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
        (boundary_sentences.include?(sentence) && repeated_normalized.include?(normalize_boundary_text(sentence.text)))
    end

    def repeated_exact_sentence?(sentence, repeated_exact)
      text = exact_boundary_text(sentence.text)
      repeated_exact.any? { |candidate| text == candidate || (candidate.length >= 40 && text.include?(candidate)) }
    end

    def normalize_boundary_text(text)
      exact_boundary_text(text).gsub(/\d+/, '<d>')
    end

    def exact_boundary_text(text)
      text.to_s.downcase.gsub(/\s+/, ' ').strip
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

    def extract_raw_paragraphs
      paras = @data.content&.paragraphs || []
      return paras.map { |p| p['text'] || p[:text] || p.text } unless paras.empty?

      @stl&.update 'No paragraphs found, checking alternative text'
      alt = find_alternative_text
      return [] unless alt&.strip&.length&.positive?
      [alt]
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
      page = SymMash.new(page) unless page.is_a?(SymMash)
      return unless page.header&.strip&.length&.positive?
      header_text = page.header.strip
      result = header_text unless prev_headers.include?(header_text)
      prev_headers << header_text
      result
    end

    def process_footer(page, prev_footers)
      page = SymMash.new(page) unless page.is_a?(SymMash)
      return unless page.footer&.strip&.length&.positive?
      footer_text = page.footer.strip
      result = footer_text unless prev_footers.include?(footer_text)
      prev_footers << footer_text
      result
    end

    # Detect and filter headers/footers by finding lines that appear on >30% of pages
    def filter_headers_footers(lines_data)
      return lines_data if lines_data.empty?
      
      # Normalize text for comparison (replace numbers with placeholder)
      norm = ->(s) { s.downcase.gsub(/\d+/, '<d>').gsub(/\s+/, ' ').strip }
      
      # Group lines by page
      pages_hash = lines_data.group_by { |l| l['page'] || l[:page] || (l.is_a?(SymMash) ? l.page : nil) }
      return lines_data if @metadata.selected_pages && pages_hash.size < 3

      hdrf_counts = Hash.new(0)
      
      # Count how often first/last lines appear across pages
      pages_hash.each do |_, page_lines|
        first_line = page_lines.first
        last_line = page_lines.last
        first_text = first_line&.dig('text') || first_line&.dig(:text) || (first_line.is_a?(SymMash) ? first_line.text : nil)
        last_text = last_line&.dig('text') || last_line&.dig(:text) || (last_line.is_a?(SymMash) ? last_line.text : nil)
        [first_text, last_text].compact.map(&norm).each { |l| hdrf_counts[l] ||= 0; hdrf_counts[l] += 1 }
      end
      
      threshold = [(pages_hash.size * 0.3).ceil, 3].max
      hdrf_set = hdrf_counts.select { |_, count| count >= threshold }.keys
      
      # Filter out detected headers/footers
      lines_data.reject do |l|
        text = l['text'] || l[:text] || (l.is_a?(SymMash) ? l.text : nil)
        hdrf_set.include?(norm.call(text))
      end
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
