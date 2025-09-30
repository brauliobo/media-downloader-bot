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

    def initialize(path, stl: nil)
      @path = path
      @sentences = []
      @stl = stl
      ocr!
    end

    def to_h
      { 'image' => { 'sentences' => sentences.map(&:to_h) } }
    end

    private

    # Run OCR and extract sentences
    def ocr!
      return if @sentences.any?
      
      input = path
      tmp_png = nil
      tmp_json = nil
      base = nil # Initialize to avoid scope issues
      
      # If path refers to a PDF page ("file.pdf#page=N"), rasterize the page first
      if path.to_s =~ /^(.+\.pdf)#page=(\d+)$/i
        pdf_path = $1
        page_num = $2.to_i
        base = File.join(Dir.tmpdir, "page-#{page_num}-#{SecureRandom.hex(4)}")
        tmp_png = "#{base}.png"
        
        # 1) pdftoppm
        @stl&.update "Rendering page #{page_num} with pdftoppm"
        system("pdftoppm -f #{page_num} -l #{page_num} -png -singlefile '#{pdf_path}' '#{base}'")
        
        unless File.exist?(tmp_png)
          # 2) pdfimages
          @stl&.update "pdftoppm failed, trying pdfimages for page #{page_num}"
          system("pdfimages -png -f #{page_num} -l #{page_num} '#{pdf_path}' '#{base}'")
          candidate = Dir["#{base}*.png"].min
          FileUtils.mv(candidate, tmp_png) if candidate && !File.exist?(tmp_png)
        end
        
        unless File.exist?(tmp_png)
          # 3) Ghostscript
          @stl&.update "pdfimages failed, trying ghostscript for page #{page_num}"
          system("gs -dSAFER -dBATCH -dNOPAUSE -sDEVICE=pngalpha -r200 -dFirstPage=#{page_num} -dLastPage=#{page_num} -sOutputFile='#{tmp_png}' '#{pdf_path}' 2>&1 >/dev/null")
        end
        
        if File.exist?(tmp_png)
          input = tmp_png
        else
          @stl&.update "Failed to extract page #{page_num} as image"
          return
        end
      end
      
      @stl&.update "Running OCR on image #{File.basename(input)}"
      tmp_json = File.join(Dir.tmpdir, "ocr-#{SecureRandom.hex(4)}.json")
      Ocr.transcribe(input, tmp_json, stl: @stl)
      
      unless File.exist?(tmp_json)
        @stl&.update "OCR failed - no output generated"
        return
      end
      
      data = JSON.parse(File.read(tmp_json))
      text = data['text'] || data.dig('content', 'text') || ''
      
      if text.strip.empty?
        @stl&.update "OCR returned no text"
        return
      end
      
      @stl&.update "OCR extracted #{text.length} characters, splitting into sentences"
      normalized = Ocr.util.normalize_text(text)
        .gsub(/[\u0000-\u001F\u007F-\u009F]/, '').gsub(/\u00AD/, '').gsub(/\s+/, ' ').strip
      parts = normalized.gsub(/([.!?…]\"?)\s+(?=\p{Lu})/u, "\\1\n").split(/\n+/)
      @sentences = parts.map { |s| Sentence.new(s) }.reject { |s| s.text.empty? }
      @stl&.update "Created #{@sentences.size} sentences from OCR"
    ensure
      FileUtils.rm_f(tmp_json) if tmp_json
      FileUtils.rm_f(tmp_png) if tmp_png
      Dir["#{base}*"].each { |f| FileUtils.rm_f(f) } if base && !base.empty?
    end
  end
end
