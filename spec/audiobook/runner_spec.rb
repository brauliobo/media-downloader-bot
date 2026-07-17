require 'spec_helper'

RSpec.describe Audiobook::Runner do
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
    allow(page).to receive(:to_wav).and_raise('page TTS failed')
    expect(runner).not_to receive(:create_silent_wav)

    expect { runner.process_to_audio('/tmp/audiobook.opus') }.to raise_error('page TTS failed')
  end
end
