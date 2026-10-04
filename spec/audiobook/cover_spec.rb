require 'rails_helper'

RSpec.describe Audiobook::Cover do
  def fixture_path(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  it 'renders a thumbnail from the first PDF page with an embedded image' do
    source = fixture_path('image-text-handler.pdf')
    page = Audiobook::Parsers::Pdf.extract_document(source, page_limit: 1).pages.first
    cover = described_class.from_page(source, page)

    expect(cover.page_number).to eq(1)

    Dir.mktmpdir do |dir|
      rendered = cover.thumbnail(dir: dir, base: 'book')
      expect(rendered).to end_with('-cover-othumb.jpg')
      expect(File.size(rendered)).to be_positive
      dimensions, = Sh.run ['identify', '-format', '%w %h', rendered]
      expect(dimensions.split.map(&:to_i).max).to be <= 320
    end
  end

  it 'renders a thumbnail from the first PDF page when it has no embedded image' do
    source = fixture_path('page-paragraphs-merge.pdf')
    page = Audiobook::Parsers::Pdf.extract_document(source, page_limit: 1).pages.first
    cover = described_class.from_page(source, page)

    expect(cover.page_number).to eq(1)

    Dir.mktmpdir do |dir|
      rendered = cover.thumbnail(dir: dir, base: 'book')
      expect(rendered).to end_with('-cover-othumb.jpg')
      expect(File.size(rendered)).to be_positive
    end
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

  it 'rasterizes the first source page for the book thumb' do
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
