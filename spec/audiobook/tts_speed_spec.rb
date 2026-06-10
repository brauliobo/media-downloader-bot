require 'spec_helper'

RSpec.describe 'Audiobook TTS speed' do
  it 'builds speech options with speed and default voice instruction' do
    book = instance_double(Audiobook::Book, metadata: {}, pages: [])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(speed: '1.25'))

    Dir.mktmpdir do |dir|
      options = runner.send(:tts_options, dir)

      expect(options[:speed]).to eq(1.25)
      expect(options[:instruct]).to eq(Audiobook::Runner::DEFAULT_VOICE_INSTRUCT)
    end
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
