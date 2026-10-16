require 'rails_helper'

RSpec.describe Replay::Input do
  it 'tells a book sent as a file from its options' do
    msg = SymMash.new(text: "Book.pdf\nlang=pt hashtags", document: { file_name: 'Book.pdf', file_size: 2_097_152 })

    expect(described_class.of(msg)).to include(type: 'document', file_name: 'Book.pdf', size: 2_097_152, inputs: [{ opts: { 'lang' => 'pt', 'hashtags' => 1 } }])
  end

  it 'reads the url and options of each line of a text message' do
    msg = SymMash.new(text: "https://example.com/a.mp4 audio\nhttps://example.com/b.mp4")

    expect(described_class.of(msg)).to include(type: 'text', inputs: [{ url: 'https://example.com/a.mp4', opts: { 'audio' => 1 } }, { url: 'https://example.com/b.mp4' }])
  end
end
