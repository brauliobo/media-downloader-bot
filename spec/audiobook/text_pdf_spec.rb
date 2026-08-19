require 'spec_helper'

RSpec.describe Audiobook::TextPdf do
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

  it 'writes a Unicode translation PDF with chromium' do
    skip 'chromium not available' unless system('which', 'chromium', out: File::NULL, err: File::NULL)

    book = Audiobook::Book.new(data: book_data, opts: SymMash.new(includeall: true), translate: false)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'book.pt.pdf')
      expect(described_class.generate(book, path)).to eq(path)
      expect(File.binread(path, 5)).to eq('%PDF-')
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
