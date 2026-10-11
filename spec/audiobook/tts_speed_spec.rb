require 'rails_helper'

RSpec.describe 'Audiobook TTS speed' do
  let(:clone_text) { 'Esta frase de referência é longa o bastante para fixar a voz narradora durante todo o audiolivro.' }

  def duration_of(page, **options)
    Dir.mktmpdir { |dir| Prober.for(page.to_wav(dir, '0001', **options)).format.duration.to_f }
  end

  [TTS::OmniVoice, TTS::MossTTS].each do |backend|
    it "builds and reuses stable speech options for #{backend.name}" do
      tts = fake_tts(backend)
      fake_llm(gender: 'female')

      expect(narrate(sentence_book('Hello world.', 'Another one.'), SymMash.new(speed: '1.25'))).to be_positive

      reference = tts.reference
      expect(tts.calls.count { |call| call.equal?(reference) }).to eq(1)
      expect(reference).to include(instruct: 'female, middle-aged, moderate pitch', lang: 'en')
      expect(tts.narration.map { |call| call[:speaker_wav] }.uniq).to eq([reference[:out_path]])
      expect(tts.narration).to all(include(ref_text: reference[:text], instruct: 'female, middle-aged, moderate pitch'))
      expect(tts.narration).to all(satisfy { |call| !call.key?(:speed) && !call.key?(:audio_speed) })
      expect(tts.narration.map { |call| call[:temperature] }.uniq).to eq(backend == TTS::MossTTS ? [0] : [nil])
    end
  end

  it 'speeds the narration up once, not again when encoding the final audiobook' do
    book = sentence_book('Hello world.')
    fake_tts(seconds: 1)
    normal = narrate(book)
    fast   = narrate(book, SymMash.new(speed: '2'))

    expect(normal - fast).to be_within(0.15).of(0.5)
  end

  it 'uses book text instead of synthetic narration for the voice reference' do
    short_text  = 'Esta frase possui palavras suficientes para servir como uma referência de voz.'
    source_text = 'Esta frase mais longa preserva uma voz consistente durante toda a leitura do livro.'
    tts = fake_tts(TTS::MossTTS)
    fake_llm(reference: clone_text)

    narrate(book_of(Audiobook::Heading.new(short_text), Audiobook::Heading.new(source_text), metadata: { language: 'pt' }))

    expect(tts.reference).to include(text: source_text, lang: 'pt')
    expect(tts.narration).to all(include(ref_text: source_text))
  end

  it 'rejects oversized whitespace-light source text for voice references' do
    short_text = Array.new(16, '中文').join(' ')
    long_text  = Array.new(20, '这是一段明显过长的中文参考文本').join(' ')
    tts = fake_tts(TTS::OmniVoice)

    narrate(book_of(Audiobook::Heading.new(short_text), Audiobook::Heading.new(long_text), metadata: { language: 'zh' }))

    expect(tts.reference[:text]).to eq(short_text)
  end

  { 'pt' => 'male', 'en' => 'female' }.each do |language, gender|
    it "asks for a #{language} reference text and narrates #{language} audiobooks with it" do
      tts = fake_tts(TTS::OmniVoice)
      fake_llm(gender: gender, reference: clone_text)

      narrate(sentence_book('Olá.', metadata: { language: language }))

      expect(tts.reference).to include(text: clone_text, lang: language, instruct: "#{gender}, middle-aged, moderate pitch")
      expect(tts.narration).to all(include(ref_text: clone_text, lang: language))
    end
  end

  it 'falls back to a stable reference sentence when the model gives a short one' do
    tts = fake_tts(TTS::OmniVoice)
    fake_llm(reference: 'Curta.')

    narrate(sentence_book('Olá.', metadata: { language: 'pt' }))

    expect(tts.reference[:text]).to eq(Language.reference_fallback('pt'))
  end

  it 'passes the configured voice instructions, normalized, to the reference and the narration' do
    tts = fake_tts(TTS::OmniVoice)
    fake_llm(gender: 'female')

    narrate(sentence_book('Hello world.'), SymMash.new(voice: 'male,young_adult,medium_pitch,american_accent'))

    expected = 'male, young adult, moderate pitch, american accent'
    expect(tts.reference).to include(instruct: expected)
    expect(tts.narration).to all(include(instruct: expected))
  end

  it 'uses an explicit recorded voice reference without synthesizing one' do
    tts = fake_tts(TTS::OmniVoice)

    Dir.mktmpdir do |dir|
      reference = File.join(dir, 'speaker.wav')
      File.write(reference, 'wav')
      opts = SymMash.new(speaker_wav: reference, ref_text: 'Recorded reference text.', position_temperature: 0, instruct: 'female, calm')

      narrate(sentence_book('Hello world.'), opts)

      expect(tts.reference).to be_nil
      expect(tts.narration).to all(include(speaker_wav: reference, ref_text: 'Recorded reference text.',
                                           position_temperature: 0.0, instruct: 'female, calm'))
    end
  end

  describe 'with a voice link' do
    let(:reference) { VoiceReference::Candidate.new(text: 'Uma passagem clara da narradora.') }
    let(:voice)     { 'https://example.com/narrator' }

    it 'downloads and extracts a clear reference from the link' do
      tts = fake_tts(TTS::OmniVoice)
      requested = nil
      allow(VoiceReference).to receive(:from_url) { |**args| requested = args; reference }

      narrate(sentence_book('Olá.', metadata: { language: 'pt' }), SymMash.new(voice: voice))

      expect(requested).to include(url: voice, language: 'pt', reference_filter: :clone)
      expect(tts.reference).to be_nil
      expect(tts.narration).to all(include(speaker_wav: requested[:output], ref_text: 'Uma passagem clara da narradora.'))
      expect(tts.narration).to all(satisfy { |call| !call.key?(:instruct) })
    end

    it 'forwards the extraction progress to the audiobook status' do
      fake_tts(TTS::OmniVoice)
      status = AudiobookHelpers::StatusLog.new
      allow(VoiceReference).to receive(:from_url) do |on_status:, **|
        on_status.call('Transcribing voice reference')
        reference
      end

      narrate(sentence_book('Olá.', metadata: { language: 'pt' }), SymMash.new(voice: voice), stl: status)

      expect(status.lines).to include('Transcribing voice reference')
    end
  end

  it 'ignores temperature when the backend does not support it' do
    tts = fake_tts(TTS::OmniVoice)

    narrate(sentence_book('Hello world.'), SymMash.new(temp: '0.35'))

    expect(tts.calls).to all(satisfy { |call| !call.key?(:temperature) })
  end

  it 'keeps explicit voice instructions instead of the detected gender' do
    tts = fake_tts(TTS::OmniVoice)
    fake_llm(gender: 'female')

    narrate(sentence_book('Hello world.'), SymMash.new(voice: 'male,high_pitch'))

    expect(tts.calls).to all(include(instruct: 'male, high pitch'))
  end

  it 'passes the voice instruction but not the speed to spoken page items, and speeds them up afterwards' do
    page = Audiobook::Page.new(1, [Audiobook::Paragraph.new([Audiobook::Sentence.new('Hello world.')])])
    tts = fake_tts(seconds: 1)

    tts_options = { instruct: 'female, middle-aged, moderate pitch, american accent' }
    normal = duration_of(page, lang: 'en', tts_options: tts_options)
    fast   = duration_of(page, lang: 'en', tts_options: tts_options.merge(audio_speed: 2))

    expect(tts.calls).to all(include(text: 'Hello world.', lang: 'en', **tts_options))
    expect(tts.calls).to all(satisfy { |call| !call.key?(:audio_speed) })
    expect(normal - fast).to be_within(0.15).of(0.5)
  end

  it 'uses a sentence language instead of the book language for synthesis' do
    page = Audiobook::Page.new(1, [Audiobook::Paragraph.new([Audiobook::Sentence.new('Svabhávameka kavayo vadanti.', language: 'sa')])])
    tts = fake_tts

    Dir.mktmpdir { |dir| page.to_wav(dir, '0001', lang: 'en') }

    expect(tts.calls.map { |call| call.slice(:text, :lang) }).to eq([{ text: 'Svabhávameka kavayo vadanti.', lang: 'sa' }])
  end

  it 'pre-synthesizes audiobook sentences through the concurrent batch path' do
    tts    = fake_tts(TTS::OmniVoice)
    status = AudiobookHelpers::StatusLog.new
    book   = book_of(
      Audiobook::Heading.new('Chapter One.'),
      Audiobook::Paragraph.new([Audiobook::Sentence.new('Hello world.'), Audiobook::Sentence.new('Second sentence!', language: 'sa')])
    )

    narrate(book, SymMash.new(speed: '1.25', voice: 'female narrator'), stl: status)

    expect(tts.narration.map { |call| call.slice(:text, :lang) }).to contain_exactly(
      { text: 'Chapter One.', lang: 'en' }, { text: 'Hello world.', lang: 'en' }, { text: 'Second sentence!', lang: 'sa' }
    )
    expect(tts.batches).to all(include(instruct: 'female narrator'))
    expect(status.lines).to include('Processing page 1/1, item 2/2, paragraph 1/1, sentence 2/2, audio 3/3')
  end
end
