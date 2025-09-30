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
    def to_wav(dir, idx, lang: 'en', stl: nil)
      return nil if items.empty?
      
      wavs = items.each_with_index.map do |item, iidx|
        stl&.update "Processing page #{number}, item #{iidx+1}/#{items.size} (#{item.class.name.split('::').last})"
        item.to_wav(dir, "#{idx}_#{iidx}", lang: lang, stl: stl)
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
          [item.sentence]
        when Paragraph, Image
          item.sentences
        else
          []
        end
      end
    end
  end
end
