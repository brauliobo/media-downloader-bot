require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference::Transcriber do
  it 'normalizes Whisper API output for selection' do
    backend = double
    allow(backend).to receive(:transcribe).and_return(SymMash.new(
      lang: 'en',
      output: {
        language: 'english',
        segments: [{
          start: 2.5,
          end: 14.5,
          text: 'A clear spoken English sentence for the reusable reference voice selector.',
          words: [{word: 'clear', probability: 0.96}]
        }]
      }
    ))

    transcript = described_class.new(backend: backend).call('/tmp/source.wav')

    expect(backend).to have_received(:transcribe).with(
      '/tmp/source.wav', format: 'verbose_json', merge_words: false
    )
    expect(transcript[:language]).to eq('en')
    expect(transcript[:segments].first).to include(
      start: 2.5, finish: 14.5, probabilities: [0.96]
    )
  end
end
