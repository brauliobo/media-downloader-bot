require 'json'

module Audiobook
  # Represents an image that needs OCR, then generates audio like a paragraph
  class Image < Paragraph
    attr_reader :path

    # Sentences already read from it skip the OCR, as when the book is loaded back from YAML.
    def initialize(path, sentences: nil, stl: nil, page_context: nil, text: nil, opts: nil)
      @path = path
      @stl = stl
      @opts = opts
      @page_context = page_context
      @sentences = sentences || Sentence.from_text(text.presence || ocr_text)
    end

    def to_h
      data = { 'sentences' => sentences.map(&:to_h) }
      data['path'] = path if path.present?
      { 'image' => data }
    end

    private

    PDF_PAGE = /\.pdf#page=(\d+)$/i

    def ocr_text
      @stl&.update "Processing #{ocr_page_prefix}#{ocr_action}"
      OcrText.transcribe(path, stl: @stl, opts: @opts)
    end

    def ocr_page_prefix
      if @page_context
        "page #{@page_context[:current]}/#{@page_context[:total]}, "
      elsif (page = path.to_s[PDF_PAGE, 1])
        "page #{page}, "
      else
        ''
      end
    end

    def ocr_action
      path.to_s.match?(PDF_PAGE) ? 'rasterizing and running OCR' : 'running OCR'
    end
  end
end
