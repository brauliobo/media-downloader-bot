require 'spec_helper'

RSpec.describe 'Audiobook TTS speed' do
  it 'builds speech options without speed and with default detected voice instruction' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(speed: '1.25'))

    Dir.mktmpdir do |dir|
      allow(Language).to receive(:voice_reference_text).with('en').and_return(Audiobook::Runner::VOICE_REFERENCE_TEXT)
      allow(Language).to receive(:author_gender).and_return('female')
      allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
        File.write(out_path, 'wav')
      end

      options = runner.send(:tts_options, dir)

      expect(options).not_to have_key(:speed)
      expect(options[:audio_speed]).to eq(1.25)
      expect(options[:temperature]).to eq(0)
      expect(options[:instruct]).to eq('female, middle-aged, moderate pitch')
      expect(options[:speaker_wav]).to end_with('audiobook_voice_reference.wav')
      expect(options[:ref_text]).to eq(Audiobook::Runner::VOICE_REFERENCE_TEXT)
    end
  end

  it 'uses language-specific reference text for non-English audiobooks' do
    book = instance_double(Audiobook::Book, metadata: { 'language' => 'pt' }, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new)

    Dir.mktmpdir do |dir|
      captured = nil
      allow(Language).to receive(:voice_reference_text).with('pt').and_return('Esta frase fixa a voz narradora do audiolivro.')
      allow(Language).to receive(:author_gender).and_return('male')
      allow(TTS).to receive(:synthesize) do |**kwargs|
        captured = kwargs
        File.write(kwargs[:out_path], 'wav')
      end

      options = runner.send(:tts_options, dir)

      expect(captured[:text]).to eq('Esta frase fixa a voz narradora do audiolivro.')
      expect(captured[:lang]).to eq('pt')
      expect(captured[:instruct]).to eq('male, middle-aged, moderate pitch')
      expect(options[:ref_text]).to eq('Esta frase fixa a voz narradora do audiolivro.')
    end
  end

  it 'keeps explicitly configured voice instructions for Portuguese audiobooks' do
    book = instance_double(Audiobook::Book, metadata: { 'language' => 'pt' }, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(voice: 'male,calm,portuguese_accent'))

    expect(runner.send(:voice_instruct)).to eq('male, calm, portuguese accent')
  end

  it 'uses language-specific voice reference text for English audiobooks too' do
    book = instance_double(Audiobook::Book, metadata: { language: 'en' }, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new)

    Dir.mktmpdir do |dir|
      allow(Language).to receive(:voice_reference_text).with('en').and_return('This sentence anchors the narrator voice.')
      allow(Language).to receive(:author_gender).and_return('male')
      allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
        File.write(out_path, 'wav')
      end

      expect(runner.send(:tts_options, dir)[:ref_text]).to eq('This sentence anchors the narrator voice.')
    end
  end

  it 'passes configured TTS temperature option' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(temp: '0.35'))

    allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
      File.write(out_path, 'wav')
    end

    Dir.mktmpdir do |dir|
      allow(Language).to receive(:voice_reference_text).with('en').and_return(Audiobook::Runner::VOICE_REFERENCE_TEXT)
      allow(Language).to receive(:author_gender).and_return('male')

      expect(runner.send(:tts_options, dir)[:temperature]).to eq(0.35)
    end
  end

  it 'keeps audiobook batching disabled by default' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(batch_size: '100'))

    allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
      File.write(out_path, 'wav')
    end

    Dir.mktmpdir do |dir|
      allow(Language).to receive(:voice_reference_text).with('en').and_return(Audiobook::Runner::VOICE_REFERENCE_TEXT)
      allow(Language).to receive(:author_gender).and_return('male')

      expect(runner.send(:tts_options, dir)).not_to have_key(:tts_batch_size)
    end
  end

  it 'accepts batch_size as an alias when batching is enabled' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(batch: 'true', batch_size: '100'))

    allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
      File.write(out_path, 'wav')
    end

    Dir.mktmpdir do |dir|
      allow(Language).to receive(:voice_reference_text).with('en').and_return(Audiobook::Runner::VOICE_REFERENCE_TEXT)
      allow(Language).to receive(:author_gender).and_return('male')

      expect(runner.send(:tts_options, dir)[:tts_batch_size]).to eq(100)
    end
  end

  it 'uses batch size 100 by default when batching is enabled' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(tts_batch: 'true'))

    allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
      File.write(out_path, 'wav')
    end

    Dir.mktmpdir do |dir|
      allow(Language).to receive(:voice_reference_text).with('en').and_return(Audiobook::Runner::VOICE_REFERENCE_TEXT)
      allow(Language).to receive(:author_gender).and_return('male')

      expect(runner.send(:tts_options, dir)[:tts_batch_size]).to eq(100)
    end
  end

  it 'detects author gender from the first pages and omits accent' do
    page = Audiobook::Page.new(1, [
      Audiobook::Heading.new('Frankenstein'),
      Audiobook::Paragraph.new([Audiobook::Sentence.new('By Mary Shelley.')])
    ])
    book = instance_double(Audiobook::Book, metadata: { 'title' => 'Frankenstein' }, pages: [page])
    runner = Audiobook::Runner.new(book, nil, SymMash.new)

    allow(Language).to receive(:voice_reference_text).with('en').and_return(Audiobook::Runner::VOICE_REFERENCE_TEXT)
    allow(Language).to receive(:author_gender) do |input|
      expect(input).to include('Frankenstein')
      expect(input).to include('Mary Shelley')
      'female'
    end
    allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
      File.write(out_path, 'wav')
    end

    Dir.mktmpdir do |dir|
      expect(runner.send(:tts_options, dir)[:instruct]).to eq('female, middle-aged, moderate pitch')
    end
  end

  it 'keeps explicit voice instructions instead of detected gender defaults' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(voice: 'male,high_pitch'))

    allow(Language).to receive(:voice_reference_text).with('en').and_return(Audiobook::Runner::VOICE_REFERENCE_TEXT)
    allow(Language).to receive(:author_gender).and_raise('should not detect')
    allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
      File.write(out_path, 'wav')
    end

    Dir.mktmpdir do |dir|
      expect(runner.send(:tts_options, dir)[:instruct]).to eq('male, high pitch')
    end
  end

  it 'does not reapply conversion speed to the final audiobook encode' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(speed: '1.25'))
    captured_opts = nil

    allow(Zipper).to receive(:zip_audio) do |_input, _output, opts:, **_kwargs|
      captured_opts = opts
    end

    runner.send(:encode_audio_file, '/tmp/in.wav', '/tmp/out.opus')

    expect(captured_opts.speed).to be_nil
  end

  it 'does not advertise TTS speech speed for audiobooks' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book)

    expect(runner.send(:backend_supports?, :speech_speed)).to eq(false)
  end

  it 'normalizes configured voice option values' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(
      book, nil,
      SymMash.new(voice: 'male,young_adult,moderate_pitch,american_accent')
    )

    expect(runner.send(:voice_instruct)).to eq(
      'male, young adult, moderate pitch, american accent'
    )
  end

  it 'maps medium pitch to OmniVoice moderate pitch' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(voice: 'male,medium_pitch'))

    expect(runner.send(:voice_instruct)).to eq('male, moderate pitch')
  end

  it 'passes voice instruction but not speed to spoken page items' do
    page = Audiobook::Page.new(1, [
      Audiobook::Paragraph.new([
        Audiobook::Sentence.new('Hello world.')
      ])
    ])

    Dir.mktmpdir do |dir|
      allow(Zipper).to receive(:get_pause_file).and_return(nil)
      allow(Zipper).to receive(:concat_audio) do |_inputs, outfile, **_kwargs|
        File.write(outfile, 'combined')
        outfile
      end

      expect(TTS).to receive(:synthesize).with(
        text:     'Hello world.',
        lang:     'en',
        out_path: kind_of(String),
        instruct: 'female, middle-aged, moderate pitch, american accent'
      ) do |out_path:, **_kwargs|
        File.write(out_path, 'wav')
      end
      expect(Audiobook::AudioFiles).to receive(:speed!).with(kind_of(String), 1.25)

      page.to_wav(
        dir, '0001',
        lang: 'en',
        tts_options: {
          audio_speed: 1.25,
          instruct: 'female, middle-aged, moderate pitch, american accent',
        }
      )
    end
  end

  it 'pre-synthesizes page sentences in a generic TTS batch' do
    page = Audiobook::Page.new(1, [
      Audiobook::Heading.new('Chapter One.'),
      Audiobook::Paragraph.new([
        Audiobook::Sentence.new('Hello world.'),
        Audiobook::Sentence.new('Second sentence!')
      ])
    ])

    Dir.mktmpdir do |dir|
      allow(Zipper).to receive(:get_pause_file).and_return(nil)
      allow(Zipper).to receive(:concat_audio) do |_inputs, outfile, **_kwargs|
        File.write(outfile, 'combined')
        outfile
      end

      expect(Audiobook::AudioFiles).to receive(:speed_all) do |paths, speed|
        expect(paths).to all(end_with('.wav'))
        expect(speed).to eq(1.25)
      end

      expect(TTS).to receive(:synthesize_batch) do |items:, **kwargs|
        expect(kwargs[:tts_batch_size]).to eq(100)
        expect(kwargs).not_to have_key(:speed)
        expect(kwargs).not_to have_key(:audio_speed)
        expect(items.map { |item| item[:text] }).to eq([
          'Chapter One.',
          'Hello world.',
          'Second sentence!',
        ])
        items.each { |item| File.write(item[:out_path], 'wav') }
      end

      page.to_wav(
        dir, '0001',
        lang: 'en',
        tts_options: { audio_speed: 1.25, tts_batch_size: 100 }
      )
    end
  end
end
