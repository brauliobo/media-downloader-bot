require 'spec_helper'

RSpec.describe Audiobook::Cover do
  def fixture_path(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  it 'detects and renders a large embedded image on the first page' do
    source = fixture_path('image-text-handler.pdf')
    page = Audiobook::Parsers::Pdf.extract_document(source, page_limit: 1).pages.first
    cover = described_class.detect(source, page: page)

    expect(cover).to be_a(described_class)
    expect(cover.page_number).to eq(1)
    expect(cover.area_coverage).to be >= described_class::MIN_AREA_COVERAGE

    Dir.mktmpdir do |dir|
      rendered = cover.thumbnail(dir: dir, base: 'book')
      expect(rendered).to end_with('-cover-othumb.jpg')
      expect(File.size(rendered)).to be_positive
      dimensions, = Sh.run ['identify', '-format', '%w %h', rendered]
      expect(dimensions.split.map(&:to_i).max).to be <= 320
    end
  end

  it 'detects stacked full-page image strips as a cover' do
    page   = SymMash.new(number: 1, width: 595, height: 842)
    status = instance_double(Process::Status, success?: true)
    rows   = 5.times.map { |i| "1 #{i} image 1800 568 rgb 3 8 jpeg no 10 0 272 273 45K 1.5%" }
    allow(Sh).to receive(:run).and_return(["#{rows.join("\n")}\n", '', status])

    cover = described_class.detect('book.pdf', page: page)

    expect(cover).to be_a(described_class)
    expect(cover.page_number).to eq(1)
    expect(cover.source_path).to eq('book.pdf')
  end

  it 'skips a first page without a large embedded image' do
    source = fixture_path('page-paragraphs-merge.pdf')
    page = Audiobook::Parsers::Pdf.extract_document(source, page_limit: 1).pages.first

    expect(described_class.detect(source, page: page)).to be_nil
  end

  it 'does not use a loose page image as the thumb when no PDF source is stored' do
    image = Audiobook::Image.allocate
    image.instance_variable_set(:@path, 'small-image.jpg')
    image.instance_variable_set(:@sentences, [])
    book = Audiobook::Book.allocate
    book.instance_variable_set(:@metadata, SymMash.new(cover: nil))
    book.instance_variable_set(:@pages, [Audiobook::Page.new(1, [image])])

    expect(book.thumb(dir: '/tmp', base: 'book')).to be_nil
  end

  it 'rasterizes the first source page when cover detection finds no large image' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'book.pdf')
      File.write(path, '%PDF-1.4')
      book = Audiobook::Book.allocate
      book.instance_variable_set(:@metadata, SymMash.new(cover: nil, source_path: path, page_width: 595, page_height: 842))
      rendered = instance_double(described_class, thumbnail: File.join(dir, 'book-cover-othumb.jpg'))
      allow(described_class).to receive(:from_page).and_return(rendered)

      expect(book.thumb(dir: dir, base: 'book')).to eq(File.join(dir, 'book-cover-othumb.jpg'))
    end
  end
end
