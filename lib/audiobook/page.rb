require_relative '../zipper'
require_relative 'heading'
require_relative 'paragraph'
require_relative 'image'

module Audiobook
  class Page
    PAUSE = 0

    attr_reader :number, :items

    def initialize(number, items = [])
      @number = number
      @items = items
    end

    def empty?
      items.empty?
    end

    def to_h
      { 'page' => { 'number' => number, 'items' => items.map(&:to_h) } }
    end

    # Generate combined wav for all items on this page
    def to_wav(dir, idx, lang: 'en', stl: nil, para_context: nil, page_context: nil, book_metadata: {})
      return nil if items.empty?
      
      # Count paragraphs for context
      para_count = items.count { |i| i.is_a?(Audiobook::Paragraph) }
      base_para = para_context ? para_context[:current] : 0
      total_paras = para_context ? para_context[:total] : para_count
      
      # Page context for status messages
      page_idx = page_context ? page_context[:current] : number
      page_total = page_context ? page_context[:total] : number
      is_ocr_book = !!book_metadata['fully_ocr']
      
      # Pre-calculate and set paragraph attributes
      para_counter = base_para
      items.each_with_index do |item, iidx|
        # Common attributes for all items that respond to them
        if item.respond_to?(:page_idx=)
          item.page_idx = page_idx
          item.page_total = page_total
        end

        if item.is_a?(Audiobook::Paragraph)
          para_counter += 1
          item.para_idx = para_counter
          item.para_total = total_paras
          item.page_num = number
          item.item_idx = iidx + 1
          item.item_total = items.size
          item.lang = lang
          item.stl = stl
          item.dir = dir
          item.idx = "#{idx}_#{iidx}"
          item.is_ocr = is_ocr_book || item.is_a?(Audiobook::Image)
        end
      end
      
      wavs = Array.new(items.size)
      items.each_with_index.peach do |item, iidx|
        if item.is_a?(Audiobook::Paragraph)
          wavs[iidx] = item.to_wav
        else
          # For non-paragraphs (headings), show status
          operation = item.class.name.split('::').last
          status_parts = ["page #{page_idx}/#{page_total}", "item #{iidx+1}/#{items.size}", operation]
          status_line = "Processing #{status_parts.join(', ')}"
          status_line << " (OCR)" if is_ocr_book
          stl&.update status_line
          wavs[iidx] = item.to_wav(dir, "#{idx}_#{iidx}", lang: lang, stl: stl)
        end
      end
      
      wavs.compact!
      return nil if wavs.empty?
      
      combined = File.join(dir, "page_#{idx}.wav")
      Zipper.concat_audio(wavs, combined)
      combined
    end

    # Extract all sentences from all items for translation
    def all_sentences
      items.flat_map do |item|
        case item
        when Heading
          [item]  # Heading is a Sentence
        when Paragraph, Image
          # Paragraph sentences plus any reference sentences attached to them
          item.sentences.flat_map do |s|
            refs = (s.references || []).flat_map { |r| r.sentences }
            [s, *refs]
          end
        else
          []
        end
      end
    end
  end
end
