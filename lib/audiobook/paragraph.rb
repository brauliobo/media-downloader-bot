require_relative 'sentence'
require_relative 'heading'
require_relative '../zipper'

module Audiobook
  class Paragraph

    PAUSE = 0.20

    attr_reader :sentences
    attr_accessor :para_idx, :para_total, :page_num, :item_idx, :item_total, :lang, :stl, :dir, :idx, :page_idx, :page_total, :is_ocr

    def initialize(sentences = [])
      @sentences = sentences
    end

    def empty?
      sentences.empty?
    end

    def to_h
      { 'paragraph' => { 'sentences' => sentences.map(&:to_h) } }
    end

    # Generate combined wav for this paragraph
    def to_wav
      return nil if sentences.empty?
      
      wavs = sentences.each_with_index.flat_map do |sent, sidx|
        status_parts = []
        
        page_str = "page "
        if page_idx && page_total
          page_str << "#{page_idx}/#{page_total}"
        elsif page_num
          page_str << page_num.to_s
        end
        status_parts << page_str

        status_parts << "item #{item_idx}/#{item_total}" if item_idx && item_total
        status_parts << "paragraph #{para_idx}/#{para_total}" if para_idx && para_total
        status_parts << "sentence #{sidx+1}/#{sentences.size}"
        
        status_line = "Processing #{status_parts.join(', ')}"
        status_line << " (OCR)" if defined?(@is_ocr) && @is_ocr
        
        stl&.update status_line
        main_wav = sent.to_wav(dir, "#{idx}_#{sidx}", lang: lang || 'en')
        ref_wavs = (sent.references || []).each_with_index.flat_map do |ref, ridx|
          stl&.update "Processing reference #{ref.id} for sentence #{sidx+1}/#{sentences.size}"
          ref.sentences.each_with_index.map do |rs, j|
            wav_path = rs.to_wav(dir, "#{idx}_#{sidx}_r#{ridx}_#{j}", lang: lang || 'en')
            if j == 0
              Zipper.prepend_silence!(wav_path, 0.15, dir: dir)
            end
            wav_path
          end
        end
        [main_wav, *ref_wavs]
      end
      
      combined = File.join(dir, "para_#{idx}.wav")
      Zipper.concat_audio(wavs, combined)
      combined
    end

    # Discover paragraphs from Line objects (with font metadata)
    # Returns array of { item:, page: } hashes
    def self.discover_from_lines(lines)
      return [] if lines.empty?
      
      items_with_pages = []
      buf = []
      prev_line = nil
      start_page = nil
      
      lines.each do |line|
        start_page ||= line.page_number
        should_break = false
        
        if buf.any? && prev_line
          # Dehyphenate across lines
          if prev_line.ends_with_hyphen? && line.starts_with_lowercase?
            buf[-1] = Audiobook::Line.new(buf.last.text.chomp('-') + line.text, 
                                          font_size: prev_line.font_size, 
                                          page_number: prev_line.page_number)
            prev_line = buf.last
            next
          end
          
          # Check break conditions
          font_changed = line.font_changed?(prev_line)
          page_changed = line.page_number != prev_line.page_number
          
          # Always break if line is only numbers (page numbers, etc)
          is_only_numbers = line.text.match?(/^\d+$/)
          
          # Check if both lines look like parts of a multi-line heading
          both_heading_like = prev_line.word_count <= 5 && line.word_count <= 5 && 
                             !prev_line.ends_with_punctuation? && !line.ends_with_punctuation? && prev_line.starts_with_capital? && line.starts_with_capital?
          
          # default break rules
          should_break = is_only_numbers || font_changed || (prev_line.ends_with_punctuation? && line.starts_with_capital?)

          # If the new line begins with inline reference marker(s) like "1 " or "1 2 ",
          # it is a continuation of the same paragraph, not a new one.
          if should_break
            should_break = false if Audiobook::TextHelpers.starts_with_ref_markers?(line.text)
          end
          
          # Do not force a break on short+capital lines; this often splits normal paragraphs (e.g., proper names)
          
          # Override: if page changed but no punctuation and no font change, continue the paragraph
          if page_changed && !prev_line.ends_with_punctuation? && !font_changed && !is_only_numbers
            should_break = false
          end
        end
        
        if should_break
          items = create_items_from_lines(buf, start_page)
          items_with_pages.concat(items)
          buf = [line]
          start_page = line.page_number
        else
          buf << line
        end
        prev_line = line
      end
      
      if buf.any?
        items = create_items_from_lines(buf, start_page)
        items_with_pages.concat(items)
      end
      
      items_with_pages.reject { |data| data[:item].is_a?(Paragraph) && data[:item].empty? }
    end

    # Legacy discover for text strings (EPUB, etc)
    def self.discover(raw_paragraphs)
      raw_paragraphs.map do |para_text|
        normalized = Audiobook::TextHelpers.normalize_text(para_text)
        next if normalized.empty?
        
        sentences = normalized.gsub(/([.!?…]\"?)\s+(?=\p{Lu})/u, "\\1\n").split(/\n+/)
          .map { |s| Sentence.new(s) }.reject { |s| s.text.empty? }
        
        heading_like?(sentences.first&.text) && sentences.size == 1 ? Heading.new(sentences.first.text) : new(sentences)
      end.compact.reject { |item| item.is_a?(Paragraph) && item.empty? }
    end

    # Create items from lines, splitting by font size
    # Returns array of { item:, page: } hashes
    def self.create_items_from_lines(lines, start_page)
      return [] if lines.empty?
      
      # Group lines by font size to prevent merging different-sized text
      grouped_by_font = []
      current_group = []
      prev_font = nil
      
      lines.each do |line|
        # Start new group if font changed or line is only numbers
        if prev_font && line.font_size && (line.font_size != prev_font || line.text.match?(/^\d+$/))
          grouped_by_font << current_group unless current_group.empty?
          current_group = [line]
        else
          current_group << line
        end
        prev_font = line.font_size
      end
      grouped_by_font << current_group unless current_group.empty?
      
      # Create one item per font group
      grouped_by_font.map do |group|
        next if group.empty?
        
        # Join preserving explicit line boundaries, then fix artifacts caused by line wraps
        normalized = Audiobook::TextHelpers.join_pdf_lines(group.map(&:text))
        normalized = normalized.gsub(/\bN\s*\.\s*T\./i, 'N.T.')
        next if normalized.empty?
        
        # Split into sentences
        sentences = Audiobook::TextHelpers.split_sentences(normalized)
          .map { |s| Sentence.new(s) }.reject { |s| s.text.empty? }
        next if sentences.empty?
        
        # Detect heading vs paragraph
        first_line = group.first
        # Never create a heading from numeric-only or non-letter tokens (e.g., "1", "1 2")
        numeric_only = sentences.size == 1 && sentences.first.text.strip.match?(/\A[^\p{L}]*\z/u)

        item = if !numeric_only && sentences.size == 1 && (first_line.heading_like? || heading_like?(sentences.first.text))
          heading_sentence = sentences.first
          heading_sentence.font_size = first_line.font_size if heading_sentence.respond_to?(:font_size=)
          Heading.new(heading_sentence)
        else
          para = new(sentences)
          if first_line.font_size
            para.sentences.each { |s| s.font_size = first_line.font_size if s.respond_to?(:font_size=) }
          end
          para
        end

        { item: item, page: start_page, font_size: first_line.font_size }
      end.compact
    end

    def self.heading_like?(text)
      return false unless text
      # Never consider numeric-only or non-letter tokens as a heading
      return false if text.strip.match?(/\A[^\p{L}]*\z/u)
      words = text.split(/\s+/)
      return false if words.empty? || words.size > 10
      
      # Very short (1-3 words) without sentence-ending punctuation
      return true if words.size <= 3 && text !~ /[.!?]$/
      
      # Mostly uppercase (>60% of words)
      upper_ratio = words.count { |w| w == w.upcase && w.length > 1 }.fdiv(words.size)
      return true if upper_ratio > 0.6
      
      # Title case (all words start with capital) without sentence-ending punctuation
      words.all? { |w| w.match?(/\A[A-Z]/) } && text !~ /[.!?]$/
    end
  end
end
