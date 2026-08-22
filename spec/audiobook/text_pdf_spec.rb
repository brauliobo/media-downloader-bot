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
    heading.font_size = 16
    heading.alignment = :center
    heading.bold = true
    section.font_size = 18
    section.alignment = :center
    section.bold = true
    sentence.font_size = 12
    sentence.alignment = :left
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
    expect(html).to include('<h1 style="font-size: 18pt; text-align: center; font-weight: bold">Part One</h1>')
    expect(html).to include('<h2 style="font-size: 16pt; text-align: center; font-weight: bold">Chapter</h2>')
    expect(html).to include('<p style="font-size: 12pt">First sentence. [1] Second sentence.</p>')
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

  it 'keeps long body paragraphs justified instead of inheriting center' do
    sentence = Audiobook::Sentence.new('A long translated paragraph that should not be centered on the page.')
    sentence.font_size = 12
    sentence.alignment = :center
    book = Audiobook::Book.allocate
    book.instance_variable_set(:@pages, [Audiobook::Page.new(1, [Audiobook::Paragraph.new([sentence])])])
    book.instance_variable_set(:@metadata, SymMash.new(language: 'pt', title: 'Book'))

    html = described_class.new(book).build_html

    expect(html).to include('<p style="font-size: 12pt">A long translated paragraph that should not be centered on the page.</p>')
    expect(html).not_to include('text-align: center')
  end

  it 'announces translated PDF generation on the status line' do
    book = Audiobook::Book.new(data: book_data, opts: SymMash.new(includeall: true), translate: false)
    stl  = instance_double('StatusLine', update: nil)
    pdf  = described_class.new(book, stl: stl)
    allow(pdf).to receive(:convert_html_to_pdf)

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'book.pt.pdf')
      File.write(path, '%PDF-')
      pdf.generate(path)
    end

    expect(stl).to have_received(:update).with('Generating translated PDF')
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

  it 'generates a PDF with unusable parent XDG directories' do
    skip 'chromium not available' unless system('which', 'chromium', out: File::NULL, err: File::NULL)

    book = Audiobook::Book.new(data: book_data, opts: SymMash.new(includeall: true), translate: false)
    Dir.mktmpdir do |dir|
      blocked_path = File.join(dir, 'not-a-directory')
      File.write(blocked_path, '')
      previous = %w[XDG_CONFIG_HOME XDG_CACHE_HOME].to_h { |key| [key, ENV[key]] }
      ENV['XDG_CONFIG_HOME'] = blocked_path
      ENV['XDG_CACHE_HOME']  = blocked_path

      path = File.join(dir, 'book.pt.pdf')
      expect(described_class.generate(book, path)).to eq(path)
      expect(File.binread(path, 5)).to eq('%PDF-')
    ensure
      previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    end
  end
end
