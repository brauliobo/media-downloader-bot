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
      current_para = para_context ? para_context[:current] : 0
      total_paras = para_context ? para_context[:total] : para_count
      
      wavs = items.each_with_index.map do |item, iidx|
        stl&.update "Processing page #{number}, item #{iidx+1}/#{items.size} (#{item.class.name.split('::').last})"
        
        # Pass paragraph context to paragraphs
        if item.is_a?(Audiobook::Paragraph) && para_context
          current_para += 1
          item.to_wav(dir, "#{idx}_#{iidx}", lang: lang, stl: stl, para_idx: current_para, para_total: total_paras)
        else
          item.to_wav(dir, "#{idx}_#{iidx}", lang: lang, stl: stl)
        end
      end.compact
      
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
