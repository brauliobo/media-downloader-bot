require 'rails_helper'

RSpec.describe Audiobook::Yaml, '.parse_item' do
  it 'reads each kind of item by the key that names it' do
    expect(described_class.parse_item(heading: { text: 'Title', role: 'chapter' })).to be_a(Audiobook::Heading).and have_attributes(role: :chapter)
    expect(described_class.parse_item(section: { text: 'Part', level: 2 })).to be_a(Audiobook::Section).and have_attributes(level: 2)
    expect(described_class.parse_item(reference: { id: '1', sentences: [{ text: 'Note.' }] })).to be_a(Audiobook::Reference)
    expect(described_class.parse_item(paragraph: { sentences: [{ text: 'One.' }, { text: 'Two.' }] }).sentences.map(&:text)).to eq(%w[One. Two.])
  end

  it 'gives back an image without reading it again' do
    expect(Ocr).not_to receive(:transcribe)

    image = described_class.parse_item(image: { path: 'a.png', sentences: [{ text: 'Seen.' }] })

    expect(image).to be_a(Audiobook::Image).and have_attributes(path: 'a.png')
    expect(image.sentences.map(&:text)).to eq(['Seen.'])
  end

  it 'reads the legacy shape that names its kind in a type field' do
    expect(described_class.parse_item(type: 'Heading', text: 'Old')).to be_a(Audiobook::Heading)
    expect(described_class.parse_item(type: 'Paragraph', sentences: [{ text: 'Old.' }])).to be_a(Audiobook::Paragraph)
  end

  it 'drops what has nothing to say' do
    expect(described_class.parse_item(heading: { text: '...' })).to be_nil
    expect(described_class.parse_item(paragraph: { sentences: [] })).to be_nil
  end
end
