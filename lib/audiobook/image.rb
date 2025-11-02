require 'json'
require 'securerandom'
require 'fileutils'
require 'tmpdir'
require_relative 'paragraph'
require_relative '../ocr'

module Audiobook
  # Represents an image that needs OCR, then generates audio like a paragraph
  class Image < Paragraph
    attr_reader :path

    def initialize(path, stl: nil, page_context: nil)
      @path = path
      @sentences = []
      @stl = stl
      @page_context = page_context
      ocr!
    end

    def to_h
      { 'image' => { 'sentences' => sentences.map(&:to_h) } }
    end

    private

    # Run OCR and extract sentences
    def ocr!
      return if @sentences.any?

      page_str = ""
      if @page_context
        page_str = "page #{@page_context[:current]}/#{@page_context[:total]}, "
      elsif path.to_s =~ /^(.+\.pdf)#page=(\d+)$/i
        page_str = "page #{$2}, "
      end

      input = path
      tmp_png = nil
      base = nil # Initialize to avoid scope issues
      
      # If path refers to a PDF page ("file.pdf#page=N"), rasterize the page first
      if path.to_s =~ /^(.+\.pdf)#page=(\d+)$/i
        pdf_path = $1
        page_num = $2.to_i
        base = File.join(Dir.tmpdir, "page-#{page_num}-#{SecureRandom.hex(4)}")
        tmp_png = "#{base}.png"

        # 1) pdftoppm
        system("pdftoppm -f #{page_num} -l #{page_num} -png -singlefile '#{pdf_path}' '#{base}'")

        unless File.exist?(tmp_png)
          # 2) pdfimages
          system("pdfimages -png -f #{page_num} -l #{page_num} '#{pdf_path}' '#{base}'")
          candidate = Dir["#{base}*.png"].min
          FileUtils.mv(candidate, tmp_png) if candidate && !File.exist?(tmp_png)
        end

        unless File.exist?(tmp_png)
          # 3) Ghostscript
          system("gs -dSAFER -dBATCH -dNOPAUSE -sDEVICE=pngalpha -r200 " \
                 "-dFirstPage=#{page_num} -dLastPage=#{page_num} " \
                 "-sOutputFile='#{tmp_png}' '#{pdf_path}' 2>&1 >/dev/null")
        end

        if File.exist?(tmp_png)
          input = tmp_png
        else
          return
        end
      end

      ocr_msg = path.to_s =~ /^(.+\.pdf)#page=(\d+)$/i ? "rasterizing and running OCR" : "running OCR"
      @stl&.update "Processing #{page_str}#{ocr_msg}"
      data = Ocr.transcribe(input, stl: @stl)

      unless data && (data.text || data.content&.text)
        return
      end

      text = data.text || data.content&.text || ''

      return if text.strip.empty?

      normalized = Audiobook::TextHelpers.normalize_text(text)
      parts = normalized.gsub(/([.!?…]\"?)\s+(?=\p{Lu})/u, "\\1\n").split(/\n+/)
      @sentences = parts.map { |s| Sentence.new(s) }.reject { |s| s.text.empty? }
    ensure
      FileUtils.rm_f(tmp_png) if tmp_png
      Dir["#{base}*"].each { |f| FileUtils.rm_f(f) } if base && !base.empty?
    end
  end
end
