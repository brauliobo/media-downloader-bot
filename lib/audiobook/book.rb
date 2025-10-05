require 'json'
require 'yaml'
require 'set'
require 'fileutils'
require_relative 'parsers/pdf'
require_relative 'parsers/epub'
require_relative 'text_helpers'
require_relative '../ocr'
require_relative 'line'
require_relative 'sentence'
require_relative 'paragraph'
require_relative 'reference'
require_relative 'heading'
require_relative 'image'
require_relative 'page'
require_relative '../translator'

module Audiobook
  # Represents an intermediate structured manuscript that can be saved as YAML.
  class Book
    attr_reader :metadata, :pages

    # Alias for backward compatibility
    def items
      pages.flat_map(&:items)
    end

    def paragraphs
      items
    end

    def self.from_input(input_path, opts: nil, stl: nil)
      ext = File.extname(input_path).downcase
      case ext
      when '.yml', '.yaml' then from_yaml(input_path, opts: opts, stl: stl)
      when '.json'
        data = SymMash.new(JSON.parse(File.read(input_path)))
        new(data: data, opts: opts, stl: stl)
      when '.pdf'
        stl&.update "Analyzing document and extracting text..."
        data = Parsers::Pdf.parse(input_path, stl: stl, opts: opts)
        stl&.update "Structuring content and processing images..."
        new(data: data, opts: opts, stl: stl)
      when '.epub'
        stl&.update "Analyzing document and extracting text..."
        data = Parsers::Epub.parse(input_path, stl: stl, opts: opts)
        stl&.update "Structuring content and processing images..."
        new(data: data, opts: opts, stl: stl)
          else
            data = Ocr.transcribe(input_path, opts: opts, stl: stl)
            new(data: data, opts: opts, stl: stl)
      end
    end

    def self.from_yaml(yaml_path, opts: nil, stl: nil)
      data = YAML.load_file(yaml_path) || {}
      # Support both new format (no metadata) and legacy format (with metadata)
      metadata = data['metadata'] || {}
      
      # Parse pages or legacy items
      pages = if data['pages']
        (data['pages'] || []).map do |page_data|
          page_info = page_data['page'] || {}
          number = page_info['number'] || 0
          items = (page_info['items'] || []).map { |item| parse_item(item) }.compact
          Page.new(number, items)
        end
      else
        # Legacy format: single page with all items
        items = (data['items'] || []).map { |item| parse_item(item) }.compact
        [Page.new(1, items)]
      end
      
      obj = allocate
      obj.instance_variable_set(:@data, nil)
      obj.instance_variable_set(:@metadata, metadata)
      obj.instance_variable_set(:@opts, opts || SymMash.new)
      obj.instance_variable_set(:@stl, stl)
      obj.instance_variable_set(:@lang, metadata['language'] || 'en')
      obj.instance_variable_set(:@pages, pages)
      obj
    end

    def self.parse_item(item)
      # Item is a hash with single key indicating type
      if item['heading']
        Heading.new(item['heading']['text'])
      elsif item['reference']
        ref_info = item['reference']
        sentences = (ref_info['sentences'] || []).map do |s|
          sent = Sentence.new(s['text'])
          # nested references unlikely, ignore
          sent
        end
        Reference.new(ref_info['id'], sentences)
      elsif item['image']
        img = Image.allocate
        img.instance_variable_set(:@path, item['image']['path'] || '')
        sentences = (item['image']['sentences'] || []).map { |s| Sentence.new(s['text']) }
        img.instance_variable_set(:@sentences, sentences)
        img
      elsif item['paragraph']
        sentences = (item['paragraph']['sentences'] || []).map do |s|
          sent = Sentence.new(s['text'])
          if s['references']
            sent.references = s['references'].map do |r|
              ref_info = r['reference'] || r
              ref_sents = (ref_info['sentences'] || []).map { |rs| Sentence.new(rs['text']) }
              Reference.new(ref_info['id'], ref_sents)
            end
          end
          sent
        end
        Paragraph.new(sentences)
      else
        # Legacy format fallback with 'type' field
        type = item['type']
        case type
        when 'Heading'
          Heading.new(item['text'])
        when 'Image'
          img = Image.allocate
          img.instance_variable_set(:@path, item['path'] || '')
          sentences = (item['sentences'] || []).map { |s| Sentence.new(s['text']) }
          img.instance_variable_set(:@sentences, sentences)
          img
        else
          sentences = (item['sentences'] || []).map { |s| Sentence.new(s['text']) }
          Paragraph.new(sentences)
        end
      end
    end

    def initialize(data:, opts: nil, stl: nil)
      @data = data
      @metadata = @data.metadata || {}
      @opts = opts || SymMash.new
      @stl = stl
      @lang = @metadata.language || 'en'
      
      # Handle new line-based format or legacy paragraph format
      if @data.content&.lines
        @pages = pages_from_lines(@data.content.lines, @data.content.images || [])
        # After OCR, refine language detection if there were OCR pages
        refine_language_detection! if @metadata.has_ocr_pages
      else
        @pages = pages_from_paragraphs
      end
      
      translate! if translation_needed?
    end

    # Write YAML file following class hierarchy representation
    def write(yaml_path)
      lang_code = @metadata['language'] || @lang || 'en'
      book_hash = { 'language' => lang_code, 'pages' => pages.map(&:to_h) }
      begin
        File.write(yaml_path, YAML.dump(book_hash, line_width: -1))
      rescue ArgumentError
        File.write(yaml_path, YAML.dump(book_hash))
      end
    end

    private

    # Build pages from Line objects (new format with font metadata)
    def pages_from_lines(lines_data, images_data = [])
      # Filter headers/footers unless includeall option is set
      include_all = @data.opts&.includeall
      filtered_lines = include_all ? lines_data : filter_headers_footers(lines_data)
      
      # Create Line objects
      lines = filtered_lines.map do |l|
        Line.new(l['text'], font_size: l['font_size'], y_position: l['y'], page_number: l['page'])
      end.reject(&:empty?)
      
      # Discover paragraphs across all pages (handles cross-page paragraphs)
      items_with_pages = Paragraph.discover_from_lines(lines)

      # Pre-compute body font per page as the most frequent paragraph font size
      body_font_by_page = Hash.new { |h, k| h[k] = nil }
      font_counts_by_page = Hash.new { |h, k| h[k] = Hash.new(0) }
      items_with_pages.each do |entry|
        item = entry[:item]
        next unless item.is_a?(Paragraph)
        fs = entry[:font_size]
        next unless fs
        # round to 0.1 to merge tiny variations
        font_counts_by_page[entry[:page]][(fs.to_f * 10).round / 10.0] += 1
      end
      font_counts_by_page.each do |page, counts|
        mode_pair = counts.max_by { |_, c| c }
        body_font_by_page[page] = mode_pair&.first
      end

      # Attach inline reference markers and collect footnote paragraphs
      # Strategy:
        # - Detect numeric-only paragraphs as reference markers (e.g., "5") on a page
        # - Attach a Reference(id: "5") to the last sentence of the previous paragraph on same page
        # - Move any paragraphs whose first sentence starts with that number (e.g., "5 Lorem ...")
        #   into the Reference object and remove them from the items list
        # - If subsequent paragraphs (same font size as footnotes) appear before the next marker,
        #   attach them to the last reference on that page (supports multi-paragraph notes)
      ref_map = Hash.new { |h, k| h[k] = {} } # { page => { '5' => Reference } }
      pending_refs = Hash.new { |h, k| h[k] = [] }
      # For markers that appear between lines inside a paragraph (e.g., after a word),
      # when the previous paragraph's last sentence doesn't end with punctuation yet,
      # defer attaching and bind to the first sentence of the next paragraph on the same page.
      attach_to_next = Hash.new { |h, k| h[k] = [] }
      last_ref_by_page = {}
      last_para_by_page = {}

      # Pre-pass: detect inline markers appended to words/punctuation, e.g., "Troyes.1" or "Eschenbach2"
      # Remove the numeric token from the sentence and attach the reference to this sentence
      items_with_pages.each do |entry|
        item = entry[:item]
        next unless item.is_a?(Paragraph)
        page_num = entry[:page]
        item.sentences.each do |sent|
          new_text, ids = Audiobook::TextHelpers.strip_inline_markers(sent.text)
          if ids.any?
            sent.instance_variable_set(:@text, new_text)
            ids.each do |id|
              ref = ref_map[page_num][id] ||= Reference.new(id)
              sent.add_reference(ref)
              last_ref_by_page[page_num] = ref
            end
          end
        end
      end

      marker_id_for = lambda do |item|
        extract_ids = lambda do |raw|
          text = raw.to_s.strip
          # Accept sequences like "1" or "1 2" or "1,2" as multiple markers
          tokens = text.scan(/\d+/)
          tokens
        end

        case item
        when Paragraph
          next unless item.sentences.size == 1
          extract_ids.call(item.sentences.first.text)
        when Heading
          extract_ids.call(item.text)
        end
      end

      # First pass: identify markers and attach to previous paragraph's last sentence
      processed = []
      items_with_pages.each do |entry|
        item = entry[:item]
        page_num = entry[:page]

        item_font = entry[:font_size]

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

            pending_refs[page_num] << { ref: ref, min_idx: processed.size }
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
        item = entry[:item]
        page_num = entry[:page]
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
              if (entry_info = queue.find { |info| info[:ref].equal?(ref) })
                entry_info[:min_idx] = idx + 1
              end
              item.sentences.first.instance_variable_set(:@text, leading_match[2])
              ref.add_sentences(item.sentences)
              pending_refs[page_num].reject! { |info| info[:ref].equal?(ref) && info[:min_idx] <= idx }
              last_ref_by_page[page_num] = ref
              next
            end
          elsif (info = queue.find { |data| data[:min_idx] <= idx })
            body_font = body_font_by_page[page_num]
            line_font = entry[:font_size]
            if body_font && line_font && line_font < body_font.to_f - 1.0
              ref = info[:ref]
              info[:min_idx] = idx + 1
              ref.add_sentences(item.sentences)
              last_ref_by_page[page_num] = ref
              pending_refs[page_num].delete(info)
              next
            end
          else
            ref = last_ref_by_page[page_num]
            body_font = body_font_by_page[page_num]
            line_font = entry[:font_size]
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
        item = entry[:item]
        if item.is_a?(Paragraph) && item.sentences.any? && merged_items.any?
          prev_entry = merged_items[-1]
          prev_item = prev_entry[:item]
          if prev_item.is_a?(Paragraph)
            page_changed = entry[:page] > prev_entry[:page]
            font_close = entry[:font_size] && prev_entry[:font_size] ? (entry[:font_size] - prev_entry[:font_size]).abs < 0.6 : true
            if font_close
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
                    prev_last.instance_variable_set(:@text, merged_text)
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
      pages_hash = Hash.new { |h, k| h[k] = [] }
      items_with_pages.each do |item_data|
        page_num = item_data[:page]
        pages_hash[page_num] << item_data[:item]
      end
      
      # Add Image objects for image-only pages (they will OCR themselves)
      total_pages = @metadata.page_count
      images_data.each do |img_data|
        page_num = img_data['page']
        path = img_data['path']
        next unless path
        
        page_context = total_pages ? { current: page_num, total: total_pages } : nil
        # Image will handle rasterization and OCR in its initializer
        pages_hash[page_num] << Image.new(path, stl: @stl, page_context: page_context)
      end
      
      # Create Page objects
      pages_hash.sort.map { |page_num, items| Page.new(page_num, items) }
    end

    # Build pages from legacy paragraph format
    def pages_from_paragraphs
      paras_with_pages = extract_paragraphs_with_pages
      pages_hash = {}
      paras_with_pages.each do |para_data|
        page_nums = para_data[:page_numbers] || [1]
        page_num = page_nums.first
        pages_hash[page_num] ||= []
        pages_hash[page_num] << para_data[:text]
      end
      
      pages_hash.sort.map do |page_num, texts|
        items = Paragraph.discover(texts)
        Page.new(page_num, items)
      end
    end

    # ---------- extraction helpers ----------
    def extract_paragraphs_with_pages
      paras = @data.content&.paragraphs || []
      unless paras.empty?
        return paras.map { |p| { text: p['text'], page_numbers: p['page_numbers'] || [1] } }
      end

      @stl&.update 'No paragraphs found, checking alternative text'
      alt = find_alternative_text
      return [] unless alt&.strip&.length&.positive?
      [{ text: alt, page_numbers: [1] }]
    end

    def extract_raw_paragraphs
      paras = @data.content&.paragraphs || []
      return paras.map { |p| p['text'] } unless paras.empty?

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
      pages_text = @data.content.pages.map { |page| page['text'] }.compact.join(' ')
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
      return unless page['header']&.strip&.length&.positive?
      header_text = page['header'].strip
      result = header_text unless prev_headers.include?(header_text)
      prev_headers << header_text
      result
    end

    def process_footer(page, prev_footers)
      return unless page['footer']&.strip&.length&.positive?
      footer_text = page['footer'].strip
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
      pages_hash = lines_data.group_by { |l| l['page'] || l[:page] }
      hdrf_counts = Hash.new(0)
      
      # Count how often first/last lines appear across pages
      pages_hash.each do |_, page_lines|
        first_text = page_lines.first&.dig('text') || page_lines.first&.dig(:text)
        last_text = page_lines.last&.dig('text') || page_lines.last&.dig(:text)
        [first_text, last_text].compact.map(&norm).each { |l| hdrf_counts[l] += 1 }
      end
      
      # If a line appears on >30% of pages, it's likely a header/footer
      threshold = (pages_hash.size * 0.3).ceil
      hdrf_set = hdrf_counts.select { |_, c| c >= threshold }.keys
      
      # Filter out detected headers/footers
      lines_data.reject do |l|
        text = l['text'] || l[:text]
        hdrf_set.include?(norm.call(text))
      end
    end

    # ---------- language detection ----------
    def refine_language_detection!
      @stl&.update 'Detecting language from OCR content'
      sample_paras = pages.flat_map(&:all_sentences).first(5).map { |s| { text: s.text } }
      detected = Ocr.detect_language(sample_paras) || 'en'
      @lang = detected
      @metadata['language'] = detected
      @stl&.update "Detected language: #{detected}"
    end

    # ---------- translation ----------
    def translation_needed?
      return false unless @opts&.lang
      @opts.lang.to_s != @lang.to_s
    end

    def translate!
      @stl&.update 'Translating pages'
      @pages.each_with_index do |page, pidx|
        page.all_sentences.each_with_index do |sent, sidx|
          @stl&.update "Translating page #{pidx+1}/#{@pages.size} sentence #{sidx+1}"
          sent_text = Translator.translate(sent.text, from: @lang, to: @opts.lang)
          sent.instance_variable_set(:@text, sent_text)
        end
      end
      @lang = @opts.lang.to_s
      @metadata['language'] = @lang
    end
  end
end
