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

  it 'skips a first page without a large embedded image' do
    source = fixture_path('page-paragraphs-merge.pdf')
    page = Audiobook::Parsers::Pdf.extract_document(source, page_limit: 1).pages.first

    expect(described_class.detect(source, page: page)).to be_nil
  end

  it 'does not fall back to an image-only page after PDF cover inspection' do
    image = Audiobook::Image.allocate
    image.instance_variable_set(:@path, 'small-image.jpg')
    image.instance_variable_set(:@sentences, [])
    book = Audiobook::Book.allocate
    book.instance_variable_set(:@metadata, SymMash.new(cover: nil))
    book.instance_variable_set(:@pages, [Audiobook::Page.new(1, [image])])

    expect(book.thumb(dir: '/tmp', base: 'book')).to be_nil
  end
end
