require 'rails_helper'

RSpec.describe Dubbing::TargetVoice do
  let(:dir) { Dir.mktmpdir('target-voice-spec-') }
  let(:reference) { TTS::Reference.new(path: File.join(dir, 'speaker.wav'), text: 'English reference.') }

  after { FileUtils.remove_entry(dir) }

  it 'keeps the candidate closest to the recorded voice and clones it with the text it speaks' do
    allow(TTS).to receive(:synthesize_batch) { |items:, **| items.each { |item| File.write(item.fetch(:out_path), 'raw') } }
    scorer = ->(sample:, **) { {cosine_similarity: sample.end_with?('-3.wav') ? 0.8 : 0.4} }

    voice = described_class.new(reference, text: 'Olá, tudo bem?', lang: 'pt', options: {}, scorer: scorer).call

    expect(voice).to eq(TTS::Reference.new(path: File.join(dir, 'target-voice-3.wav'), text: 'Olá, tudo bem?'))
    expect(TTS).to have_received(:synthesize_batch).with(
      hash_including(speaker_wav: reference.path, ref_text: reference.text, items: have_attributes(size: described_class::CANDIDATES))
    )
  end
end
