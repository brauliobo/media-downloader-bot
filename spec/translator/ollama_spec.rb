require 'rails_helper'

RSpec.describe Translator::Ollama do
  subject(:translator) { Class.new { extend Translator::Ollama } }

  it 'translates the segments in one request and joins them back with the marker' do
    expect(AI::Ollama).to receive(:chat).once.and_return({ translations: %w[Um Dois] }.to_json)

    expect(translator.translate("a#{described_class::MARKER}b", from: 'en', to: 'pt')).to eq("Um#{described_class::MARKER}Dois")
  end

  it 'asks again for each segment when the model returns the wrong count' do
    allow(AI::Ollama).to receive(:chat) { |messages, format: nil, **| format ? { translations: ['only one'] }.to_json : "alone-#{messages.last[:content]}" }

    expect(translator.translate(%w[x y], from: 'en', to: 'pt')).to eq(%w[alone-x alone-y])
  end

  it 'reads a reply that is not JSON as the translation itself' do
    allow(AI::Ollama).to receive(:chat).and_return('plain text')

    expect(translator.translate('hello', from: 'en', to: 'pt')).to eq('plain text')
  end
end
