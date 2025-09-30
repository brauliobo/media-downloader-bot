require 'json'
require 'yaml'
require 'set'
require 'fileutils'
require_relative '../ocr'
require_relative 'line'
require_relative 'sentence'
require_relative 'paragraph'
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
      when '.json'         then new(input_path, opts: opts, stl: stl)
      when '.pdf', '.epub'
        tmp = File.join(Dir.mktmpdir, "#{File.basename(input_path, File.extname(input_path))}.json")
        Ocr.transcribe(input_path, tmp, stl: stl, opts: opts)
        book = new(tmp, opts: opts, stl: stl)
        FileUtils.rm_f(tmp)
        book
      else
        new(input_path, opts: opts, stl: stl)
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
      elsif item['image']
        img = Image.allocate
        img.instance_variable_set(:@path, item['image']['path'] || '')
        sentences = (item['image']['sentences'] || []).map { |s| Sentence.new(s['text']) }
        img.instance_variable_set(:@sentences, sentences)
        img
      elsif item['paragraph']
        sentences = (item['paragraph']['sentences'] || []).map { |s| Sentence.new(s['text']) }
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

    def initialize(json_path, opts: nil, stl: nil)
      @data = JSON.parse(File.read(json_path))
      @metadata = @data['metadata'] || {}
      @opts = opts || SymMash.new
      @stl = stl
      @lang = @metadata['language'] || 'en'
      
      # Handle new line-based format or legacy paragraph format
      if @data.dig('content', 'lines')
        @pages = pages_from_lines(@data['content']['lines'], @data.dig('content', 'images') || [])
      else
        @pages = pages_from_paragraphs
      end
      
      translate! if translation_needed?
    end

    # Write YAML file following class hierarchy representation
    def write(yaml_path)
      book_hash = { 'pages' => pages.map(&:to_h) }
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
      include_all = @data.dig('opts', 'includeall') || @data.dig('opts', :includeall)
      filtered_lines = include_all ? lines_data : filter_headers_footers(lines_data)
      
      # Create Line objects
      lines = filtered_lines.map do |l|
        Line.new(l['text'], font_size: l['font_size'], y_position: l['y'], page_number: l['page'])
      end.reject(&:empty?)
      
      # Discover paragraphs across all pages (handles cross-page paragraphs)
      items_with_pages = Paragraph.discover_from_lines(lines)
      
      # Group items by their page number
      pages_hash = Hash.new { |h, k| h[k] = [] }
      items_with_pages.each do |item_data|
        page_num = item_data[:page]
        pages_hash[page_num] << item_data[:item]
      end
      
      # Add Image objects for image-only pages (they will OCR themselves)
      images_data.each do |img_data|
        page_num = img_data['page']
        path = img_data['path']
        next unless path
        
        # Image will handle rasterization and OCR in its initializer
        pages_hash[page_num] << Image.new(path, stl: @stl)
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

    def self.heading_line?(text)
      return false unless text
      words = text.split(/\s+/)
      return false if words.empty? || words.size > 10
      upper_ratio = words.count { |w| w == w.upcase }.fdiv(words.size)
      return true if upper_ratio > 0.8
      return true if words.all? { |w| w.match?(/\A[A-Z][a-z]+\z/) }
      false
    end

    # ---------- extraction helpers ----------
    def extract_paragraphs_with_pages
      paras = @data.dig('content', 'paragraphs') || []
      unless paras.empty?
        return paras.map { |p| { text: p['text'], page_numbers: p['page_numbers'] || [1] } }
      end

      @stl&.update 'No paragraphs found, checking alternative text'
      alt = find_alternative_text
      return [] unless alt&.strip&.length&.positive?
      [{ text: alt, page_numbers: [1] }]
    end

    def extract_raw_paragraphs
      paras = @data.dig('content', 'paragraphs') || []
      return paras.map { |p| p['text'] } unless paras.empty?

      @stl&.update 'No paragraphs found, checking alternative text'
      alt = find_alternative_text
      return [] unless alt&.strip&.length&.positive?
      [alt]
    end

    def find_alternative_text
      return @data['text'] if @data['text']
      return @data['content']['text'] if @data.dig('content', 'text')
      return extract_pages_text if @data.dig('content', 'pages')
      return extract_headers_footers if @data.dig('metadata', 'pages')
    end

    def extract_pages_text
      pages_text = @data['content']['pages'].map { |page| page['text'] }.compact.join(' ')
      pages_text.empty? ? nil : pages_text
    end

    def extract_headers_footers
      pages_text = []
      prev_headers = Set.new
      prev_footers = Set.new

      @data['metadata']['pages'].each do |page|
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
