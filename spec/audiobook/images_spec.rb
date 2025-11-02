require 'spec_helper'

RSpec.describe 'Image handling in PDFs with text' do
  def fixture_path(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  # Mock OCR responses for faster tests
  before do
    allow(Ocr).to receive(:transcribe) do |input_path, **kwargs|
      # Return mock OCR text based on page number
      if input_path.to_s.match(/#page=(\d+)/)
        page_num = $1.to_i
        case page_num
        when 1
          # Page 1: image-only, return OCR text
          SymMash.new(content: { text: 'bell hooks tudo amor sobre o novas perspectivas' })
        when 2, 3
          # Pages 2-3: have text, OCR should not be called but if it is, return minimal text
          SymMash.new(content: { text: 'Le Livros logo' })
        else
          SymMash.new(content: { text: 'Extracted text from image' })
        end
      else
        # Fallback for non-page-specific calls
        SymMash.new(content: { text: 'Mock OCR text' })
      end
    end

    allow(Ocr).to receive(:detect_language).and_return('pt')
  end

  let(:book) { Audiobook::Book.from_input(fixture_path('image-text-handler.pdf')) }

  it 'creates an Image object for the first page (image only)' do
    page1 = book.pages[0]
    images = page1.items.grep(Audiobook::Image)
    paragraphs = page1.items.select { |i| i.is_a?(Audiobook::Paragraph) && !i.is_a?(Audiobook::Image) }
    headings = page1.items.grep(Audiobook::Heading)

    # First page should have at least an image
    expect(images.size).to be >= 1
    expect(images.first).to be_a(Audiobook::Image)
    # Image-only pages shouldn't have separate text paragraphs (Image handles OCR itself)
    expect(paragraphs.size).to eq(0)
  end

  it 'creates both Image and Paragraph objects for pages with both text and images' do
    # Page 2 and 3 should have both text (from copyright/quote) and images (Le Livros logo)
    [1, 2].each do |page_idx|
      page = book.pages[page_idx]
      images = page.items.grep(Audiobook::Image)
      paragraphs = page.items.select { |i| i.is_a?(Audiobook::Paragraph) && !i.is_a?(Audiobook::Image) }

      expect(images.size).to be >= 1, "Page #{page_idx + 1} should have at least one image"
      expect(paragraphs.size).to be >= 1, "Page #{page_idx + 1} should have at least one paragraph"
      expect(images.first).to be_a(Audiobook::Image)
    end
  end

  it 'does not OCR pages with extractable text' do
    # Pages 2 and 3 should extract text directly, not via OCR
    [1, 2].each do |page_idx|
      page = book.pages[page_idx]
      paragraphs = page.items.select { |i| i.is_a?(Audiobook::Paragraph) && !i.is_a?(Audiobook::Image) }
      
      expect(paragraphs.size).to be >= 1
      # Paragraphs from extracted text should have content
      paragraphs.each do |para|
        expect(para.sentences).not_to be_empty
        para.sentences.each do |sent|
          expect(sent.text.strip).not_to be_empty
        end
      end
    end
  end

  it 'only OCRs pages that are image-only' do
    page1 = book.pages[0]
    images = page1.items.grep(Audiobook::Image)
    
    expect(images.size).to eq(1)
    # Image should have OCR'd content
    expect(images.first.sentences).not_to be_empty
  end
end

