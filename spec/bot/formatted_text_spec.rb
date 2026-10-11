require 'rails_helper'

RSpec.describe Bot::FormattedText do
  let(:formatted) { Struct.new(:text) }
  let(:text_content)  { Struct.new(:text).new(formatted.new('hello')) }
  let(:media_content) { Struct.new(:caption).new(formatted.new('a caption')) }

  it 'reads the text of a text message' do
    expect(described_class.of(text_content)).to eq('hello')
  end

  it 'reads the caption of a media message' do
    expect(described_class.of(media_content)).to eq('a caption')
  end

  it 'is empty for a message with neither' do
    expect(described_class.of(Object.new)).to eq('')
  end
end
