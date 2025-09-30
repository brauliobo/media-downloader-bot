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
    def to_wav(dir, idx, lang: 'en', stl: nil, para_context: nil)
      return nil if items.empty?
      
      # Count paragraphs for context
      para_count = items.count { |i| i.is_a?(Audiobook::Paragraph) }
      base_para = para_context ? para_context[:current] : 0
      total_paras = para_context ? para_context[:total] : para_count
      
      # Pre-calculate and set paragraph attributes
      para_counter = base_para
      items.each_with_index do |item, iidx|
        next unless item.is_a?(Audiobook::Paragraph)
        
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
      end
      
      wavs = Array.new(items.size)
      items.each_with_index.peach do |item, iidx|
        if item.is_a?(Audiobook::Paragraph)
          wavs[iidx] = item.to_wav
        else
          # For non-paragraphs (headings, images), show the old status format
          stl&.update "Processing page #{number}, item #{iidx+1}/#{items.size} (#{item.class.name.split('::').last})"
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
          item.sentences
        else
          []
        end
      end
    end
  end
end
