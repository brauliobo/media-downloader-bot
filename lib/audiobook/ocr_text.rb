require 'fileutils'
require 'securerandom'
require_relative '../ocr'
require_relative '../utils/sh'

module Audiobook
  class OcrText
    PDF_PAGE_RE = /\A(.+\.pdf)#page=(\d+)\z/i

    def self.transcribe(path, stl: nil, opts: nil)
      input = path
      tmp_png = nil
      base = nil

      if (match = path.to_s.match(PDF_PAGE_RE))
        pdf_path = match[1]
        page_num = match[2].to_i
        base = File.join(Dir.pwd, "page-#{page_num}-#{SecureRandom.hex(4)}")
        tmp_png = rasterize_pdf_page(pdf_path, page_num, base)
        return '' unless tmp_png

        input = tmp_png
      end

      text_from(Ocr.transcribe(input, opts: opts, stl: stl))
    ensure
      FileUtils.rm_f(tmp_png) if tmp_png
      Dir["#{base}*"].each { |f| FileUtils.rm_f(f) } if base
    end

    def self.text_from(data)
      (data&.text || data&.content&.text || '').to_s
    end

    def self.rasterize_pdf_page(pdf_path, page_num, base)
      tmp_png = "#{base}.png"
      Sh.run "pdftoppm -f #{page_num} -l #{page_num} -png -singlefile #{Sh.escape(pdf_path)} #{Sh.escape(base)}"
      return tmp_png if File.exist?(tmp_png)

      Sh.run "pdfimages -png -f #{page_num} -l #{page_num} #{Sh.escape(pdf_path)} #{Sh.escape(base)}"
      candidate = Dir["#{base}*.png"].min
      FileUtils.mv(candidate, tmp_png) if candidate
      return tmp_png if File.exist?(tmp_png)

      Sh.run "gs -dSAFER -dBATCH -dNOPAUSE -sDEVICE=pngalpha -r200 " \
             "-dFirstPage=#{page_num} -dLastPage=#{page_num} " \
             "-sOutputFile=#{Sh.escape(tmp_png)} #{Sh.escape(pdf_path)}"
      File.exist?(tmp_png) ? tmp_png : nil
    end
  end
end
