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
    book = instance_double(Audiobook::Book, metadata: {}, pages: [page], translation_needed?: false, author_gender: 'female')
    runner = described_class.new(book)

    allow(Language).to receive(:voice_reference_text).with('en').and_return(described_class::VOICE_REFERENCE_TEXT)
    allow(Language).to receive(:book_metadata).and_return('title' => '', 'author' => '', 'gender' => 'female')
    allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
      File.write(out_path, 'reference')
    end
    allow(page).to receive(:prepare_speech_items)
    allow(page).to receive(:speech_jobs).and_return([])
    allow(page).to receive(:to_wav).and_raise('page TTS failed')
    expect(runner).not_to receive(:create_silent_wav)

    expect { runner.process_to_audio('/tmp/audiobook.opus') }.to raise_error('page TTS failed')
  end

  it 'sets the speech language before pipelining translation into synthesis' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [], translation_needed?: true, speech_language: 'pt')
    runner = described_class.new(book)

    runner.send(:apply_translation!)

    expect(runner.instance_variable_get(:@lang)).to eq('pt')
  end

  it 'pipelines sentence translation into batch synthesis' do
    data = SymMash.new(
      metadata: {page_count: 1, language: 'en'},
      opts:     {includeall: true},
      content:  {
        lines: [
          {text: 'Hello world.', font_size: 12, page: 1},
          {text: 'Another sentence.', font_size: 12, page: 1},
        ],
        images: [],
      },
    )
    allow(Language).to receive(:book_metadata).and_return('title' => '', 'author' => '', 'gender' => 'male')
    allow(Translator).to receive(:translate) do |text, from:, to:|
      mapped = Array(text).map { |line| "PT(#{from}->#{to}):#{line}" }
      text.is_a?(Array) ? mapped : mapped.first
    end
    book = Audiobook::Book.new(data: data, opts: SymMash.new(lang: 'pt', includeall: true), translate: false)
    runner = described_class.new(book, nil, book.instance_variable_get(:@opts))
    synthesized = []
    allow(TTS).to receive(:synthesize_batch) do |items:, **|
      synthesized.concat(items.map { |job| job[:text] })
      items.each { |job| File.write(job[:out_path], 'wav') }
      items.map { |job| job[:out_path] }
    end
    allow(Audiobook::AudioFiles).to receive(:speed_all)

    Dir.mktmpdir do |dir|
      runner.send(:apply_translation!)
      pages = book.pages
      runner.send(:prepare_pages, pages, dir, [0], 1, 1, {})
      runner.send(:process_speech_jobs, pages, dir, {})
    end

    expect(synthesized).to contain_exactly('PT(en->pt):Hello world.', 'PT(en->pt):Another sentence.')
    expect(book.translated).to be(true)
    expect(book.metadata.language).to eq('pt')
  end
end
