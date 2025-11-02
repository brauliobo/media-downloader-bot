require_relative 'sentence'
require_relative 'heading'
require_relative 'paragraph/detector'
require_relative '../zipper'

module Audiobook
  class Paragraph

    PAUSE = 0.20

    attr_reader :sentences
    attr_accessor :para_idx, :para_total, :page_num, :item_idx, :item_total, :lang, :stl, :dir,
                  :idx, :page_idx, :page_total, :is_ocr

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
        pause_file = sent.pause_file(dir)
        main_wav = sent.to_wav(dir, "#{idx}_#{sidx}", lang: lang || 'en')
        ref_wavs = (sent.references || []).each_with_index.flat_map do |ref, ridx|
          stl&.update "Processing reference #{ref.id} for sentence #{sidx+1}/#{sentences.size}"
          ref_pause = (ridx == 0 ? Zipper.get_pause_file(0.15, dir) : nil)
          ref.sentences.each_with_index.flat_map do |rs, j|
            rs_pause = rs.pause_file(dir)
            wav_path = rs.to_wav(dir, "#{idx}_#{sidx}_r#{ridx}_#{j}", lang: lang || 'en')
            [j == 0 ? ref_pause : nil, rs_pause, wav_path].compact
          end
        end
        [pause_file, main_wav, *ref_wavs].compact
      end
      
      combined = File.join(dir, "para_#{idx}.wav")
      Zipper.concat_audio(wavs, combined)
      combined
    end

    # Discover paragraphs from Line objects (with font metadata)
    # Returns array of { item:, page: } hashes
    def self.discover_from_lines(lines)
      Detector.discover_from_lines(lines)
    end

    # Legacy discover for text strings (EPUB, etc)
    def self.discover(raw_paragraphs)
      raw_paragraphs.map do |para_text|
        normalized = Audiobook::TextHelpers.normalize_text(para_text)
        next if normalized.empty?
        
        sentences = normalized.gsub(/([.!?…]\"?)\s+(?=\p{Lu})/u, "\\1\n").split(/\n+/)
          .map { |s| Sentence.new(s) }.reject { |s| s.text.empty? }
        
        Factory.heading_like?(sentences.first&.text) && sentences.size == 1 ? Heading.new(sentences.first.text) : new(sentences)
      end.compact.reject { |item| item.is_a?(Paragraph) && item.empty? }
    end

  end
end
