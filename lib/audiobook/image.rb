require 'json'
require_relative 'paragraph'
require_relative 'ocr_text'

module Audiobook
  # Represents an image that needs OCR, then generates audio like a paragraph
  class Image < Paragraph
    attr_reader :path

    def initialize(path, stl: nil, page_context: nil, text: nil, opts: nil)
      @path = path
      @sentences = []
      @stl = stl
      @opts = opts
      @page_context = page_context
      build_sentences(text.presence || ocr_text)
    end

    def to_h
      { 'image' => { 'sentences' => sentences.map(&:to_h) } }
    end

    private

    def ocr_text
      page_str = ""
      if @page_context
        page_str = "page #{@page_context[:current]}/#{@page_context[:total]}, "
      elsif path.to_s =~ /^(.+\.pdf)#page=(\d+)$/i
        page_str = "page #{$2}, "
      end

      ocr_msg = path.to_s =~ /^(.+\.pdf)#page=(\d+)$/i ? "rasterizing and running OCR" : "running OCR"
      @stl&.update "Processing #{page_str}#{ocr_msg}"
      OcrText.transcribe(path, stl: @stl, opts: @opts)
    end

    def build_sentences(text)
      return if text.strip.empty?

      normalized = TextHelpers.normalize_text(text)
      parts = normalized.gsub(/([.!?…]\"?)\s+(?=\p{Lu})/u, "\\1\n").split(/\n+/)
      @sentences = Sentence.build_all(parts)
    end
  end
end
