require 'spec_helper'

RSpec.describe Audiobook::Runner do
  it 'applies a configured audio floor to the combined audiobook only' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    wav = '/tmp/combined.wav'

    configured = described_class.new(book, nil, SymMash.new(audio_floor_amplitude: 0.001, audio_loudness_lufs: -18))
    expect(Zipper).to receive(:add_audio_floor!).with(
      wav,
      amplitude: 0.001,
      loudness_lufs: -18.0,
      sample_rate: TTS.output_sample_rate
    ).and_return(wav)
    expect(configured.send(:add_audio_floor!, wav)).to eq(wav)

    unconfigured = described_class.new(book)
    expect(Zipper).not_to receive(:add_audio_floor!)
    expect(unconfigured.send(:add_audio_floor!, wav)).to eq(wav)
  end

  it 'propagates page synthesis failures instead of encoding a silent audiobook' do
    page = instance_double(Audiobook::Page, items: [], all_sentences: [])
    book = instance_double(Audiobook::Book, metadata: {}, pages: [page])
    runner = described_class.new(book)

    allow(Language).to receive(:voice_reference_text).with('en').and_return(described_class::VOICE_REFERENCE_TEXT)
    allow(Language).to receive(:author_gender).and_return('female')
    allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
      File.write(out_path, 'reference')
    end
    allow(page).to receive(:prepare_speech_items)
    allow(page).to receive(:speech_jobs).and_return([])
    allow(page).to receive(:to_wav).and_raise('page TTS failed')
    expect(runner).not_to receive(:create_silent_wav)

    expect { runner.process_to_audio('/tmp/audiobook.opus') }.to raise_error('page TTS failed')
  end
end
