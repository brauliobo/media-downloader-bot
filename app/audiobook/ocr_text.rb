module Audiobook
  class OcrText
    PDF_PAGE_RE = /\A(.+\.pdf)#page=(\d+)\z/i

    def self.transcribe(path, stl: nil, opts: nil)
      match = path.to_s.match(PDF_PAGE_RE)
      return recognize(path, stl: stl, opts: opts) unless match

      Utils::Tmp.dir('ocr-page-') do |dir|
        png = rasterize_pdf_page(match[1], match[2].to_i, File.join(dir, 'page'))
        png ? recognize(png, stl: stl, opts: opts) : ''
      end
    end

    def self.recognize(input, stl:, opts:)
      Utils::Tmp.cached('ocr', input, opts: opts.to_h) { text_from(Ocr.transcribe(input, opts: opts, stl: stl)) }
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
