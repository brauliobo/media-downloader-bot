require 'rails_helper'

RSpec.describe TTS::Reference do
  it 'provides the TTS voice-cloning options' do
    reference = described_class.new(path: '/tmp/speaker.wav', text: 'Reference text.')

    expect(reference.tts_options).to eq(speaker_wav: '/tmp/speaker.wav', ref_text: 'Reference text.')
  end
end

RSpec.describe TTS::Anchor do
  let(:dir)  { Dir.mktmpdir('tts-anchor-spec-') }
  let(:path) { File.join(dir, 'anchor.wav') }

  after { FileUtils.remove_entry(dir) }

  def anchor = described_class.call(text: 'Frase de referência.', lang: 'pt', path: path, instruct: 'female, calm')

  it 'synthesizes the instruction once and returns it as a reference' do
    allow(TTS).to receive(:synthesize) { |out_path:, **| File.write(out_path, 'anchor') }

    expect(anchor).to eq(TTS::Reference.new(path: path, text: 'Frase de referência.'))
    expect(TTS).to have_received(:synthesize).with(text: 'Frase de referência.', lang: 'pt', out_path: path, instruct: 'female, calm')
  end

  it 'reuses the anchor already on disk so the voice stays the same' do
    File.write(path, 'anchor')
    allow(TTS).to receive(:synthesize)

    expect(anchor.path).to eq(path)
    expect(TTS).not_to have_received(:synthesize)
  end
end
