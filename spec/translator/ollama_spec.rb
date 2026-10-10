require 'rails_helper'

RSpec.describe Translator::Ollama do
  subject(:translator) { Class.new { extend Translator::Ollama } }

  def reply(content) = double(body: { message: { content: content } }.to_json)

  it 'translates the segments in one request and joins them back with the marker' do
    expect(Utils::HTTP).to receive(:post).once.and_return(reply({ translations: %w[Um Dois] }.to_json))

    expect(translator.translate("a#{described_class::MARKER}b", from: 'en', to: 'pt')).to eq("Um#{described_class::MARKER}Dois")
  end

  it 'asks again for each segment when the model returns the wrong count' do
    allow(Utils::HTTP).to receive(:post) do |_url, body|
      request = JSON.parse(body)
      request['format'] ? reply({ translations: ['only one'] }.to_json) : reply("alone-#{request['messages'].last['content']}")
    end

    expect(translator.translate(%w[x y], from: 'en', to: 'pt')).to eq(%w[alone-x alone-y])
  end

  it 'reads a reply that is not JSON as the translation itself' do
    allow(Utils::HTTP).to receive(:post).and_return(double(body: 'plain text'))

    expect(translator.translate('hello', from: 'en', to: 'pt')).to eq('plain text')
  end
end
