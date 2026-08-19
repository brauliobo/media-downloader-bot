require 'cgi'
require_relative 'book'
require_relative '../utils/sh'

module Audiobook
  class TextPdf
    OCR_THRESHOLD = 80
    CHROMIUM_BINS = %w[chromium google-chrome-stable google-chrome chromium-browser].freeze

    def self.ocr_percentage(book)
      total_pages = book.pages.size
      return 0.0 if total_pages.zero?

      ocr_pages = if book.metadata['fully_ocr']
        total_pages
      else
        book.pages.count { |p| p.items.any? { |i| i.is_a?(Audiobook::Image) } }
      end

      (ocr_pages.to_f / total_pages * 100).round(2)
    end

    def self.should_generate?(book)
      ocr_percentage(book) > OCR_THRESHOLD
    end

    def self.generate(book, pdf_path, stl: nil)
      new(book, stl: stl).generate(pdf_path)
    end

    def initialize(book, stl: nil)
      @book = book
      @stl = stl
    end

    def generate(pdf_path)
      @stl&.update 'Generating PDF from text'
      
      html_content = build_html
      html_path = pdf_path.sub(/\.pdf$/, '.html')
      File.write(html_path, html_content)
      
      convert_html_to_pdf(html_path, pdf_path)
      File.delete(html_path) if File.exist?(html_path)
      
      raise 'Failed to generate PDF' unless File.exist?(pdf_path)
      pdf_path
    end

    private

    def build_html
      title = @book.metadata['title'] || 'Audiobook'
      lang = @book.metadata['language'] || 'en'
      
      html = html_header(title, lang)
      html << html_body
      html << html_footer
      html
    end

    def html_header(title, lang)
      <<~HTML
        <!DOCTYPE html>
        <html lang="#{lang}">
        <head>
          <meta charset="UTF-8">
          <title>#{CGI.escapeHTML(title)}</title>
          #{html_styles}
        </head>
        <body>
          <h1>#{CGI.escapeHTML(title)}</h1>
      HTML
    end

    def html_styles
      <<~CSS
        <style>
          body { font-family: serif; line-height: 1.6; max-width: 800px; margin: 0 auto; padding: 20px; }
          h1 { page-break-after: avoid; }
          p { margin: 1em 0; text-align: justify; }
        </style>
      CSS
    end

    def html_body
      html = ''
      @book.pages.each do |page|
        page.items.each do |item|
          html << render_item(item)
        end
      end
      html
    end

    def render_item(item)
      case item
      when Audiobook::Heading
        "<h2>#{CGI.escapeHTML(item.text)}</h2>\n"
      when Audiobook::Paragraph, Audiobook::Image
        item.sentences.map { |s| render_sentence(s) }.join
      else
        ''
      end
    end

    def render_sentence(sentence)
      text = CGI.escapeHTML(sentence.text)
      if sentence.references&.any?
        ref_ids = sentence.references.map(&:id).join(', ')
        text += " [#{CGI.escapeHTML(ref_ids)}]"
      end
      "<p>#{text}</p>\n"
    end

    def html_footer
      "</body></html>"
    end

    def convert_html_to_pdf(html_path, pdf_path)
      if (chrome = chromium_bin)
        chromium_convert(chrome, html_path, pdf_path)
      elsif wkhtmltopdf_available?
        wkhtmltopdf_convert(html_path, pdf_path)
      elsif pandoc_available?
        pandoc_convert(html_path, pdf_path)
      else
        raise 'No PDF generation tool available (chromium, wkhtmltopdf or pandoc required)'
      end
    end

    def chromium_bin
      CHROMIUM_BINS.find { system('which', _1, out: File::NULL, err: File::NULL) }
    end

    def wkhtmltopdf_available?
      system('which', 'wkhtmltopdf', out: File::NULL, err: File::NULL)
    end

    def pandoc_available?
      system('which', 'pandoc', out: File::NULL, err: File::NULL)
    end

    def chromium_convert(chrome, html_path, pdf_path)
      Dir.mktmpdir('chrome-pdf-') do |dir|
        run_pdf!(
          [
            chrome, '--headless', '--disable-gpu', '--no-pdf-header-footer',
            "--user-data-dir=#{dir}", "--print-to-pdf=#{pdf_path}",
            "file://#{File.expand_path(html_path)}"
          ],
          'chromium pdf',
          pdf_path
        )
      end
    end

    def wkhtmltopdf_convert(html_path, pdf_path)
      run_pdf!(
        [
          'wkhtmltopdf', '--page-size', 'A4',
          '--margin-top', '20mm', '--margin-bottom', '20mm',
          '--margin-left', '20mm', '--margin-right', '20mm',
          html_path, pdf_path
        ],
        'wkhtmltopdf',
        pdf_path
      )
    end

    def pandoc_convert(html_path, pdf_path)
      run_pdf!(['pandoc', '-f', 'html', '-t', 'pdf', '-o', pdf_path, html_path], 'pandoc pdf', pdf_path)
    end

    def run_pdf!(cmd, label, pdf_path)
      _out, err, status = Sh.run(cmd)
      Sh.assert_success!(label, err, status: status, output: pdf_path)
    end
  end
end
