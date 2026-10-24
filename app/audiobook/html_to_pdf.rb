module Audiobook
  # Prints an HTML file to PDF with the first tool installed: chromium, wkhtmltopdf or pandoc.
  module HtmlToPdf
    CHROMIUM_BINS = %w[chromium google-chrome-stable google-chrome chromium-browser].freeze
    DBUS_NOISE    = /ERROR:dbus\//

    module_function

    def call(html_path, pdf_path)
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
      CHROMIUM_BINS.find { Sh.which?(_1) }
    end

    def wkhtmltopdf_available?
      Sh.which?('wkhtmltopdf')
    end

    def pandoc_available?
      Sh.which?('pandoc')
    end

    def chromium_convert(chrome, html_path, pdf_path)
      Utils::Tmp.dir('chrome-pdf-') do |dir|
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

    # Chromium without a session bus fills stderr with DBus errors that hide why it printed nothing, and it exits 0 doing so.
    def run_pdf!(cmd, label, pdf_path, **options)
      _out, err, status = Sh.run(cmd, **options)
      err = err.lines.grep_v(DBUS_NOISE).join.presence || ('wrote no PDF' if status.success?)
      Sh.assert_success!(label, err, status: status, output: pdf_path)
    end
  end
end
