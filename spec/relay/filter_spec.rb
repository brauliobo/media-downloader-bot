require 'rails_helper'

RSpec.describe Relay::Filter do
  let(:text)  { SymMash.new(text: 'hello') }
  let(:audio) { SymMash.new(text: '', audio: {file_name: 'a.mp3'}) }

  it 'finds the media kind of a message' do
    expect(described_class.kind(audio)).to eq('audio')
    expect(described_class.kind(text)).to be_nil
  end

  it 'matches a media kind alone and everything with all' do
    expect(described_class.match?('audio', audio)).to be(true)
    expect(described_class.match?('video', audio)).to be(false)
    expect(described_class.match?('document', text)).to be(false)
    expect(described_class.match?('all', text)).to be(true)
  end
end
