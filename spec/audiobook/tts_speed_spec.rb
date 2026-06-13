require 'spec_helper'

RSpec.describe 'Audiobook TTS speed' do
  it 'builds speech options with speed and default voice instruction' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(speed: '1.25'))

    Dir.mktmpdir do |dir|
      allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
        File.write(out_path, 'wav')
      end

      options = runner.send(:tts_options, dir)

      expect(options[:speed]).to eq(1.25)
      expect(options[:temperature]).to eq(0)
      expect(options[:instruct]).to eq(Audiobook::Runner::DEFAULT_VOICE_INSTRUCT)
      expect(options[:speaker_wav]).to end_with('audiobook_voice_reference.wav')
      expect(options[:ref_text]).to eq(Audiobook::Runner::VOICE_REFERENCE_TEXT)
    end
  end

  it 'passes configured TTS temperature option' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(temp: '0.35'))

    allow(TTS).to receive(:synthesize) do |out_path:, **_kwargs|
      File.write(out_path, 'wav')
    end

    Dir.mktmpdir do |dir|
      expect(runner.send(:tts_options, dir)[:temperature]).to eq(0.35)
    end
  end

  it 'does not apply conversion speed when the TTS backend already supports speed' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(speed: '1.25'))
    captured_opts = nil

    allow(Zipper).to receive(:zip_audio) do |_input, _output, opts:, **_kwargs|
      captured_opts = opts
    end

    runner.send(:encode_audio_file, '/tmp/in.wav', '/tmp/out.opus')

    expect(captured_opts.speed).to be_nil
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

  it 'passes TTS speed and voice instruction to spoken page items' do
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
        text:     'Hello world',
        lang:     'en',
        out_path: kind_of(String),
        speed:    1.25,
        instruct: 'female, middle-aged, moderate pitch, american accent'
      ) do |out_path:, **_kwargs|
        File.write(out_path, 'wav')
      end

      page.to_wav(
        dir, '0001',
        lang: 'en',
        tts_options: {
          speed:    1.25,
          instruct: 'female, middle-aged, moderate pitch, american accent',
        }
      )
    end
  end
end
