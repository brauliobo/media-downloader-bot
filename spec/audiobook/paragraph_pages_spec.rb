require 'rails_helper'

RSpec.describe Audiobook::ParagraphPages do
  it 'says a running head or foot once, where it first appears' do
    data = SymMash.new(metadata: { pages: [{ header: 'Title', footer: '1' }, { header: 'Title', footer: '2' }] })

    expect(described_class.headers_and_footers(data)).to eq('Title 1 2')
  end

  it 'groups paragraphs under their page' do
    data = SymMash.new(content: { paragraphs: [{ text: 'First.', page_numbers: [1] }, { text: 'Second.', page_numbers: [2] }] })

    expect(described_class.build(data).map(&:number)).to eq([1, 2])
  end
end
