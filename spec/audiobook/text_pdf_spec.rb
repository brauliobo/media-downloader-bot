require 'spec_helper'

RSpec.describe Audiobook::TextPdf do
  before do
    allow(Language).to receive(:book_metadata).and_return('lang' => 'pt', 'title' => '', 'author' => '', 'gender' => 'male')
  end

  def fixture_path(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  def book_data
    SymMash.new(
      metadata: {page_count: 1, language: 'pt', title: 'Adiós a La Inflamación'},
      opts:     {includeall: true},
      content:  {
        lines: [{text: 'Olá, menopausa e inflamação.', font_size: 12, page: 1}],
        images: [],
      },
    )
  end

  def structured_book
    sentence  = Audiobook::Sentence.new('First sentence.')
    sentence.add_reference(Audiobook::Reference.new('1', [Audiobook::Sentence.new('A footnote.')]))
    paragraph = Audiobook::Paragraph.new([sentence, Audiobook::Sentence.new('Second sentence.')])
    heading   = Audiobook::Heading.new('Chapter')
    section   = Audiobook::Section.new('Part One', level: 1)
    footer    = Audiobook::Paragraph.new([Audiobook::Sentence.new('Repeated footer.')])
    image     = Audiobook::Image.allocate
    image.instance_variable_set(:@path, 'book.pdf#page=1')
    image.instance_variable_set(:@sentences, [Audiobook::Sentence.new('OCR cover text.')])
    book = Audiobook::Book.allocate
    book.instance_variable_set(:@pages, [
      Audiobook::Page.new(1, [image]),
      Audiobook::Page.new(2, [section, heading, paragraph, footer]),
    ])
    book.instance_variable_set(:@metadata, SymMash.new(language: 'pt', title: 'Book Title'))
    book
  end

  it 'keeps sentences, headings, sections, footers, and references' do
    html = described_class.new(structured_book).build_html

    expect(html).to include('<title>Book Title</title>')
    expect(html).not_to include('<h1>')
    expect(html).to include('<h2>Part One</h2>')
    expect(html).to include('<h2>Chapter</h2>')
    expect(html).to include('<p>First sentence. [1] Second sentence.</p>')
    expect(html).to include('<p>Repeated footer.</p>')
    expect(html).to include('<aside class="reference"><sup>1</sup> A footnote.</aside>')
    expect(html).to include('<p>OCR cover text.</p>')
  end

  it 'writes a Unicode translation PDF with chromium' do
    skip 'chromium not available' unless system('which', 'chromium', out: File::NULL, err: File::NULL)

    book = Audiobook::Book.new(data: book_data, opts: SymMash.new(includeall: true), translate: false)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'book.pt.pdf')
      expect(described_class.generate(book, path)).to eq(path)
      expect(File.binread(path, 5)).to eq('%PDF-')
    end
  end

  it 'embeds the cover and keeps original page text without dumping cover OCR' do
    skip 'chromium not available' unless system('which', 'chromium', out: File::NULL, err: File::NULL)

    source = fixture_path('image-text-handler.pdf')
    allow(Ocr).to receive(:transcribe).and_return(SymMash.new(content: {text: 'OCR cover dump'}))
    book = Audiobook::Book.from_input(source, opts: SymMash.new(alang: 'pt'), translate: false)

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'book.pt.pdf')
      expect(described_class.generate(book, path, source_pdf: source)).to eq(path)

      text, = Sh.run ['pdftotext', path, '-']
      expect(text).to include('SOBRE A OBRA PRESENTE')
      expect(text).to include('DADOS DE COPYRIGHT')
      expect(text).not_to include('OCR cover dump')

      list, = Sh.run ['pdfimages', '-list', path]
      expect(list.lines.count { |line| line.split[2] == 'image' }).to be >= 1
    end
  end

  it 'prefers chromium over pandoc' do
    book = Audiobook::Book.new(data: book_data, opts: SymMash.new(includeall: true), translate: false)
    pdf  = described_class.new(book)
    allow(pdf).to receive(:chromium_bin).and_return('chromium')
    allow(pdf).to receive(:chromium_convert)
    allow(pdf).to receive(:pandoc_convert)

    pdf.send(:convert_html_to_pdf, '/tmp/book.html', '/tmp/book.pdf')

    expect(pdf).to have_received(:chromium_convert)
    expect(pdf).not_to have_received(:pandoc_convert)
  end
end
