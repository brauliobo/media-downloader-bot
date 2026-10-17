require 'rails_helper'

RSpec.describe Audiobook::Runner do
  let(:floor_args) { { amplitude: 0.001, loudness_lufs: -18.0, sample_rate: TTS.output_sample_rate } }

  before { allow(Zipper::AudioOps).to receive(:add_floor!).and_call_original }

  it 'applies a configured audio floor to the combined audiobook only' do
    fake_tts

    narrate(sentence_book('Hello world.'), SymMash.new(audio_floor_amplitude: 0.001, audio_loudness_lufs: -18))
    expect(Zipper::AudioOps).to have_received(:add_floor!).once.with(a_string_ending_with('combined.wav'), **floor_args)

    narrate(sentence_book('Hello world.'))
    expect(Zipper::AudioOps).to have_received(:add_floor!).once
  end

  it 'propagates page synthesis failures instead of encoding a silent audiobook' do
    fake_tts.failure = RuntimeError.new('page TTS failed')
    allow(Kernel).to receive(:sleep)

    expect { narrate(sentence_book('Hello world.')) }.to raise_error('page TTS failed')
  end

  context 'in a job that is interrupted and taken again' do
    let(:texts) { ['First sentence.', 'Second sentence.', 'Third sentence.'] }

    around { |example| Dir.mktmpdir('job-') { |job| Utils::Tmp.within(job) { example.run } } }

    it 'reads only what the interrupted run did not' do
      tts = fake_tts
      stub_const('TTS::BATCH_SIZE', 1)
      tts.before = ->(options) { raise 'killed' if options[:text] == 'Second sentence.' }

      expect { narrate(sentence_book(*texts)) }.to raise_error('killed')
      tts.before = nil
      narrate(sentence_book(*texts))

      expect(tts.narration.map { |call| call[:text] }).to match_array(texts)
    end

    it 'does not resume in the audio of another book, and leaves nothing behind when done' do
      tts = fake_tts

      narrate(sentence_book(*texts))
      narrate(sentence_book('Another book.'))

      expect(tts.narration.map { |call| call[:text] }).to match_array(texts + ['Another book.'])
      expect(Dir.children(Utils::Tmp.root).grep(/\Aaudiobook-/)).to be_empty
    end
  end

  it 'pipelines sentence translation into batch synthesis in the speech language' do
    tts = fake_tts
    fake_translator
    lines = ['Hello world.', 'Another sentence.'].map { |text| { text: text, font_size: 12, page: 1 } }
    data  = SymMash.new(metadata: { page_count: 1, language: 'en' }, opts: { includeall: true }, content: { lines: lines, images: [] })
    opts  = SymMash.new(lang: 'pt', includeall: true)
    book  = Audiobook::Book.new(data: data, opts: opts, translate: false)

    narrate(book, opts)

    expect(tts.narration.map { |call| call.slice(:text, :lang) }).to contain_exactly(
      { text: 'PT(en->pt):Hello world.', lang: 'pt' }, { text: 'PT(en->pt):Another sentence.', lang: 'pt' }
    )
    expect(book.translated).to be(true)
    expect(book.metadata.language).to eq('pt')
  end
end
