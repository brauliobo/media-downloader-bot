require 'spec_helper'

RSpec.describe 'Reference extraction from PDF' do
  def fixture_path(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  def raw_lines_for(fixture)
    pdf = Audiobook::Parsers::Pdf.parse(fixture_path(fixture))
    pdf.content.lines.map { |l| l['text'] }
  end

  def load_reference_data(fixture)
    pdf_path = fixture_path(fixture)
    book = Audiobook::Book.from_input(pdf_path)
    pages = book.pages

    references = pages.flat_map do |page|
      page.items.flat_map do |item|
        next [] unless item.is_a?(Audiobook::Paragraph)
        item.sentences.flat_map { |sent| Array(sent.references) }
      end
    end.compact

    refs_by_page = pages.to_h do |page|
      ids = page.items.flat_map do |item|
        next [] unless item.is_a?(Audiobook::Paragraph)
        item.sentences.flat_map { |sent| Array(sent.references).map(&:id) }
      end.flatten.sort
      [page.number, ids]
    end

    paragraph_texts = pages.flat_map { |p| p.items.grep(Audiobook::Paragraph) }.flat_map(&:sentences).map(&:text)

    { pages:, references:, refs_by_page:, paragraph_texts: }
  end

  def assert_reference_expectations(data, expected_refs, forbidden_pattern: nil)
    expect(data[:refs_by_page].values).to include(expected_refs)
    expect(data[:references].map(&:id)).to all(eq(expected_refs.first))
    if forbidden_pattern
      expect(data[:paragraph_texts]).not_to include(a_string_matching(forbidden_pattern))
    end

    data[:references].each do |ref|
      expect(ref.sentences).not_to be_empty
      expect(ref.sentences.first.text).not_to match(/^\d+$/)
    end
  end

  describe 'ref1.pdf' do
    it 'extracts the single reference without leaving the footnote inline' do
      data = load_reference_data('ref1.pdf')
      assert_reference_expectations(data, ['4'], forbidden_pattern: /peixe da sabedoria/)
    end
  end

  describe 'ref2.pdf' do
    it 'extracts the single reference attached to the correct paragraph' do
      data = load_reference_data('ref2.pdf')
      assert_reference_expectations(
        data,
        ['5'],
        forbidden_pattern: /Assunto tratado por .+Transmutação - O Caminho da Consciência/i
      )
    end
  end

end

