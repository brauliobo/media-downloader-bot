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

  describe 'sequential PDFs paragraph merge' do
    it 'merges the cross-page paragraph and leaves the next page clean' do
      ref1 = load_reference_data('ref1.pdf')
      ref2 = load_reference_data('ref2.pdf')

      last_para_ref1 = ref1[:pages].last.items.grep(Audiobook::Paragraph).last
      first_page_paragraphs_ref2 = ref2[:pages].first.items.grep(Audiobook::Paragraph).map do |para|
        para.sentences.map(&:text).join(' ').gsub(/\s+/, ' ').strip
      end

      expect(last_para_ref1.sentences.map(&:text).join(' ')).to include('É o que a Igreja felix culpa')

      expected_paragraph = "É doloroso ver um rapazinho dar-se conta de que o mundo não é feito só de alegria e felicidade, como pensava, e observar a desintegração de seu frescor infantil, de sua fé, de seu otimismo. Triste, porém necessário. Se não formos expulsos do Jardim do Éden não poderá haver a Jerusalém Celestial, e na liturgia católica do Sábado de Aleluia há uma bela passagem a esse respeito: \"Oh! queda feliz, pois que deu a oportunidade para tão sublime redenção!\""
      forbidden_fragment = 'a queda do Jardim do Éden, ou seja, a evolução da consciência ingênua à total consciência do self.'

      expect(first_page_paragraphs_ref2).to include(expected_paragraph)
      expect(first_page_paragraphs_ref2.join(' ')).not_to include(forbidden_fragment)
      expect(first_page_paragraphs_ref2.join(' ')).not_to include('É o que a Igreja felix culpa')
    end
  end

end

