require 'rails_helper'

# These fixtures are parts of a real EPUB and pin the markup path, where the parser knows every
# block boundary exactly and the assembly must carry it through instead of re-guessing it.
RSpec.describe 'Audiobook markup assembly regressions' do
  def fixture(name) = File.expand_path("../fixtures/audiobook/#{name}", __dir__)

  def book_for(name, lang, **opts)
    Audiobook::Book.from_input(fixture(name), opts: SymMash.new(alang: lang, **opts), translate: false)
  end

  def items(book)     = book.pages.flat_map(&:items)
  def paragraphs(book) = items(book).grep(Audiobook::Paragraph)
  def paragraph_texts(book) = paragraphs(book).map { |para| para.sentences.map(&:text).join(' ') }
  def headings(book)  = items(book).grep(Audiobook::Heading).map(&:text)
  def item_texts(book) = paragraph_texts(book) + headings(book)

  describe 'hollis-nested-blocks.epub' do
    let(:book)  { book_for('hollis-nested-blocks.epub', 'en') }
    let(:lines) { Audiobook::Parsers::Epub.parse(fixture('hollis-nested-blocks.epub')).content.lines }

    it 'keeps every line of a poem in its own block' do
      expect(item_texts(book).find { |text| text.include?('The rude one is only one of many') })
        .not_to include('who populate my inner committee')
    end

    # Parser blocks 25 and 26: the block about Paul ends in a full stop and the next one opens a new
    # thought with "Freud labeled this energy", yet both arrive inside a single paragraph.
    it 'does not fuse a paragraph with the one that follows it' do
      expect(paragraph_texts(book).find { |text| text.include?('Freud labeled this energy') })
        .to start_with('Freud labeled this energy')
    end

    # A note is <div class="fn"><a>1</a><div class="fmtx2">body</div></div>: the label is the direct
    # text of the outer container, which is skipped because it holds a block child, so it is lost.
    it 'extracts the label of a note' do
      expect(lines.map(&:text)).to include('1')
    end

    it 'extracts the label of a note immediately before its body, so the two can be paired' do
      body = lines.index { |line| line.text.include?('His Egyptian name was Thoth') }
      expect(lines[body - 1].text).to eq('1')
    end
  end
end
