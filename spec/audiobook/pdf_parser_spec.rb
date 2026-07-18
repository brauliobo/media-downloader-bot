require 'spec_helper'

RSpec.describe Audiobook::Parsers::Pdf do
  def fixture_path(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  it 'builds the canonical document from real Poppler word boundaries' do
    document = described_class.extract_document(
      fixture_path('image-text-handler.pdf'),
      page_limit: described_class::MAX_PAGES + 1
    )

    expect(document.pages.map(&:number)).to eq([1, 2, 3])
    expect(document.pages.map { |page| page.lines.size }).to eq([0, 20, 7])

    page = document.pages[1]
    expect(page.width).to eq(612)
    expect(page.height).to eq(792)
    expect(page.lines.first.text).to eq('DADOS DE COPYRIGHT')
    expect(page.lines.first.font_size).to be_positive
    expect(page.lines.first.x).to be_positive
    expect(page.lines.first.y).to be_positive
  end

  it 'routes only a real image-only page to OCR' do
    data = described_class.extract_data(fixture_path('image-text-handler.pdf'))

    expect(data.metadata.page_count).to eq(3)
    expect(data.metadata.has_ocr_pages).to eq(true)
    expect(data.content.images.map(&:page)).to eq([1])
    expect(data.content.lines.map(&:page).uniq).to eq([2, 3])
    expect(data.content.lines.first.text).to eq('DADOS DE COPYRIGHT')
  end

  it 'preserves words, references, and geometry from a real text PDF' do
    data = described_class.extract_data(fixture_path('page-paragraphs-merge.pdf'))
    line = data.content.lines.find { |item| item.text.include?('Chrétien de Troyes') }

    expect(data.metadata.page_count).to eq(4)
    expect(data.content.images).to be_empty
    expect(line.text).to include('Chrétien de Troyes. 1')
    expect(line.text).to include('Wolfram von Eschenbach 2')
    expect(line.bottom_spacing).to be_a(Numeric)
    expect(line.x).to be_positive
  end

  it 'limits the real Poppler extraction to the requested page range' do
    document = described_class.extract_document(
      fixture_path('image-text-handler.pdf'),
      page_limit: 2
    )

    expect(document.pages.map(&:number)).to eq([1, 2])
  end
end
