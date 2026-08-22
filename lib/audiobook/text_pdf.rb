require 'cgi'
require_relative 'book'
require_relative 'cover'
require_relative 'ocr_text'
require_relative '../utils/sh'

module Audiobook
  class TextPdf
    OCR_THRESHOLD     = 80
    MIN_FIGURE_AREA   = 0.002
    CHROMIUM_BINS     = %w[chromium google-chrome-stable google-chrome chromium-browser].freeze

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

    def self.generate(book, pdf_path, stl: nil, source_pdf: nil)
      new(book, stl: stl, source_pdf: source_pdf).generate(pdf_path)
    end

    def initialize(book, stl: nil, source_pdf: nil)
      @book       = book
      @stl        = stl
      @source_pdf = source_pdf
      @assets     = nil
    end

    def generate(pdf_path)
      @stl&.update 'Generating translated PDF'
      Dir.mktmpdir('text-pdf-') do |dir|
        @assets   = dir
        html_path = File.join(dir, 'book.html')
        File.write(html_path, build_html)
        convert_html_to_pdf(html_path, pdf_path)
      end
      raise 'Failed to generate PDF' unless File.exist?(pdf_path)
      pdf_path
    end

    def build_html
      title = @book.title
      lang  = @book.language
      html_header(title, lang) + html_body + html_footer
    end

    private

    def html_header(title, lang)
      <<~HTML
        <!DOCTYPE html>
        <html lang="#{lang}">
        <head>
          <meta charset="UTF-8">
          <title>#{CGI.escapeHTML(title.to_s)}</title>
          #{html_styles}
        </head>
        <body>
      HTML
    end

    def html_styles
      body_size = @book.respond_to?(:font_roles) ? @book.font_roles&.body_size : nil
      body_rule = body_size ? "font-size: #{FontRoles.format_pt(body_size)}; " : ''
      <<~CSS
        <style>
          @page { size: A4; margin: 14mm; }
          body { font-family: serif; #{body_rule}line-height: 1.55; margin: 0; }
          h1, h2, h3, h4, h5, h6 { page-break-after: avoid; margin: 0 0 0.8em; }
          p { margin: 0 0 1em; text-align: justify; }
          aside.reference { font-size: 0.9em; margin: 0.4em 0 0; }
          .page { break-after: page; page-break-after: always; }
          .page:last-child { break-after: auto; page-break-after: auto; }
          img.cover, img.page-image { display: block; width: 100%; height: auto; }
          img.figure { display: block; max-width: 100%; height: auto; margin: 1em auto; }
        </style>
      CSS
    end

    def html_body
      html = +''
      html << cover_html
      @book.pages.each { |page| html << render_page(page) }
      html
    end

    def cover_html
      src = rasterize_page(cover_page, 'cover')
      src ? %(<div class="page"><img class="cover" src="#{src}" alt=""></div>\n) : ''
    end

    def render_page(page)
      return '' if page.empty?
      return '' if cover_page && page.number == cover_page && image_only?(page)

      inner = image_only?(page) ? render_image_page(page) : render_text_page(page)
      return '' if inner.empty?

      %(<div class="page">\n#{inner}</div>\n)
    end

    def render_image_page(page)
      src = rasterize_page(page.number, "page-#{page.number}")
      return %(<img class="page-image" src="#{src}" alt="">\n) if src

      page.items.grep(Image).map { |item| render_paragraph(item) }.join
    end

    def render_text_page(page)
      html = page.items.map { |item| render_item(item) }.join
      html << references_html(page)
      html << figures_html(page.number) unless cover_page && page.number == cover_page
      html
    end

    def render_item(item)
      case item
      when Section   then heading_html(item)
      when Heading   then heading_html(item)
      when Image     then ''
      when Reference then render_reference(item)
      when Paragraph then render_paragraph(item)
      else ''
      end
    end

    def heading_html(item)
      level = item.is_a?(Section) ? item.level : (@book.font_roles&.level_for(item) || 2)
      tag = "h#{level.to_i.clamp(1, 6)}"
      "<#{tag}#{style_attr(item)}>#{escape_text(item.text)}</#{tag}>\n"
    end

    def render_reference(item)
      body = item.sentences.filter_map { |sentence| sentence_html(sentence) }.join(' ')
      return '' if body.empty?

      %(<aside class="reference"><sup>#{escape_text(item.id)}</sup> #{body}</aside>\n)
    end

    def references_html(page)
      page_references(page).map { |item| render_reference(item) }.join
    end

    def page_references(page)
      page.items.flat_map { |item| attached_references(item) }.uniq
    end

    def attached_references(item)
      return [] if item.is_a?(Reference)
      return item.references || [] if item.is_a?(Sentence)
      return [] unless item.respond_to?(:sentences)

      item.sentences.flat_map { |sentence| sentence.references || [] }
    end

    def render_paragraph(item)
      parts = item.sentences.filter_map { |sentence| sentence_html(sentence) }
      return '' if parts.empty?

      text  = parts.join(' ')
      first = item.sentences.first
      "<p#{style_attr(first, alignment: FontRoles.flow_alignment(first, text: text, paragraph: true))}>#{text}</p>\n"
    end

    def sentence_html(sentence)
      text = escape_text(sentence.text)
      return if text.empty?

      refs = sentence.references&.map(&:id)&.join(', ')
      refs.present? ? "#{text} [#{escape_text(refs)}]" : text
    end

    def figures_html(page_num)
      extract_figures(page_num).map { |src| %(<img class="figure" src="#{src}" alt="">\n) }.join
    end

    def html_footer
      '</body></html>'
    end

    def image_only?(page)
      page.items.any? && page.items.all? { |item| item.is_a?(Image) }
    end

    def cover
      @cover ||= @book.metadata.cover || @book.metadata[:cover]
    end

    def cover_page
      cover&.page_number
    end

    def source_pdf
      @source_pdf ||= cover&.source_path || infer_source_pdf
    end

    def infer_source_pdf
      @book.pages.flat_map(&:items).grep(Image).map(&:path).find { |path|
        path.to_s =~ /\.pdf#page=/i
      }&.sub(/#page=\d+\z/i, '')
    end

    def rasterize_page(page_num, name)
      return unless source_pdf && page_num && @assets && File.exist?(source_pdf)

      base = File.join(@assets, name)
      png  = OcrText.rasterize_pdf_page(source_pdf, page_num, base)
      File.basename(png) if png && File.exist?(png)
    end

    def extract_figures(page_num)
      return [] unless source_pdf && @assets && File.exist?(source_pdf)

      images = listed_images(page_num)
      keep   = images.reject(&:large?).select { |metrics| metrics.area_coverage >= MIN_FIGURE_AREA }
      return [] if keep.empty?

      prefix = File.join(@assets, "p#{page_num}-fig")
      Sh.run ['pdfimages', '-png', '-f', page_num.to_s, '-l', page_num.to_s, source_pdf, prefix]
      Dir["#{prefix}*.png"].sort.zip(images).filter_map do |path, metrics|
        File.basename(path) if path && keep.include?(metrics)
      end
    end

    def listed_images(page_num)
      output, stderr, status = Sh.run [
        'pdfimages', '-f', page_num.to_s, '-l', page_num.to_s, '-list', source_pdf
      ]
      Sh.assert_success!('PDF image list failed', stderr, status: status)
      output.lines.filter_map { |line| Cover.image_metrics(line, page_box) }
    end

    def page_box
      @page_box ||= begin
        output, = Sh.run ['pdfinfo', source_pdf]
        width, height = output.to_s.match(/Page size:\s+([\d.]+)\s+x\s+([\d.]+)/)&.captures
        SymMash.new(width: width&.to_f || 612.0, height: height&.to_f || 792.0)
      end
    end

    def escape_text(text)
      CGI.escapeHTML(text.to_s)
    end

    def style_attr(item, alignment: :keep)
      rules = FontRoles.css_rules(item, alignment: alignment)
      rules.empty? ? '' : %( style="#{rules.join('; ')}")
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
          pdf_path,
          env: {
            'XDG_CONFIG_HOME' => dir,
            'XDG_CACHE_HOME'  => dir,
          }
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

    def run_pdf!(cmd, label, pdf_path, **options)
      _out, err, status = Sh.run(cmd, **options)
      Sh.assert_success!(label, err, status: status, output: pdf_path)
    end
  end
end
