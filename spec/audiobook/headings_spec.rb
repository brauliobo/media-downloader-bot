require 'spec_helper'

RSpec.describe 'Heading extraction from PDF' do
  def fixture_path(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  it 'captures title paragraphs and the intro heading from headings.pdf' do
    book = Audiobook::Book.from_input(fixture_path('headings.pdf'), opts: SymMash.new(alang: 'pt'))
    items = book.pages.first.items

    texts = items.flat_map { |item| item.is_a?(Audiobook::Heading) ? [item.text] : item.sentences.map(&:text) }

    expect(texts).to include('HE - A CHAVE DO ENTENDIMENTO DA PSICOLOGIA MASCULINA')
    expect(texts).to include('INTRODUÇÃO')
    expect(texts.join(' ')).to include('AUTOR: ROBERT A.')
    expect(texts.join(' ')).to include('EDITORA: MERCURYO')
    expect(items.grep(Audiobook::Heading).map(&:text)).to include('INTRODUÇÃO')
  end

end
