module Audiobook
  # Reads the document a book is made from into the structure the book is built on.
  module Source
    module_function

    def parse(input_path, format = SourceFormats.format_for_path(input_path), opts: nil, stl: nil)
      parser = format&.fetch(:parser, nil) || :parse_fallback_ocr
      public_send(parser, input_path, stl: stl, opts: opts)
    end

    def kindle?(input_path)
      s = input_path.to_s
      return false unless s.start_with?('http')

      host = URI.parse(s).host rescue nil
      Parsers::Kindle::READ_HOSTS.include?(host)
    end

    # The reader is captured as a PDF, and that PDF is what is parsed; its path travels in the
    # metadata for the upload that follows.
    def parse_kindle(input_path, opts: nil, stl: nil)
      stl&.update 'Capturing Kindle reader via browser...'
      data = Parsers::Kindle.parse(input_path, stl: stl, opts: opts)
      pdf_path = data.content&.pdf || data.pdf
      return data unless pdf_path && File.exist?(pdf_path)

      stl&.update 'Analyzing document and extracting text...'
      parsed = SymMash.wrap(Parsers::Pdf.parse(pdf_path, stl: stl, opts: opts))
      parsed.metadata = (parsed.metadata || SymMash.new).tap { |metadata| metadata.kindle_pdf = pdf_path }
      parsed
    end

    def parse_json(json_path, stl: nil, opts: nil)
      SymMash.new(JSON.parse(Yaml.read_structured(json_path)))
    end

    def parse_pdf(pdf_path, stl: nil, opts: nil)   = parse_document(Parsers::Pdf, pdf_path, stl: stl, opts: opts)

    def parse_epub(epub_path, stl: nil, opts: nil) = parse_document(Parsers::Epub, epub_path, stl: stl, opts: opts)

    def parse_document(parser, path, stl:, opts:)
      stl&.update 'Analyzing document and extracting text...'
      data = parser.parse(path, stl: stl, opts: opts)
      stl&.update 'Structuring content and processing images...'
      data
    end

    def parse_html(html_path, stl: nil, opts: nil)
      stl&.update 'Analyzing HTML document'
      Parsers::Html.parse(html_path, stl: stl, opts: opts)
    end

    def parse_txt(txt_path, stl: nil, opts: nil)
      stl&.update 'Analyzing text document'
      Parsers::Txt.parse(txt_path, stl: stl, opts: opts)
    end

    def parse_fallback_ocr(path, stl: nil, opts: nil)
      Ocr.transcribe(path, opts: opts, stl: stl)
    end
  end
end
