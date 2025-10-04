require 'spec_helper'

RSpec.describe 'Heading extraction from PDF' do
  def fixture_path(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  it 'captures title paragraphs and the intro heading from headings.pdf' do
    book = Audiobook::Book.from_input(fixture_path('headings.pdf'))
    items = book.pages.first.items

    title_paragraph = items.grep(Audiobook::Paragraph).first
    intro_heading = items.grep(Audiobook::Heading).first

    expect(title_paragraph).not_to be_nil
    expect(title_paragraph.sentences.map(&:text)).to eq(['AUTOR: ROBERT A.', 'JOHNSON EDITORA: MERCURYO'])

    expect(intro_heading).not_to be_nil
    expect(intro_heading.text).to eq('INTRODUÇÃO')
  end

end
