require 'spec_helper'

RSpec.describe 'Audiobook TTS speed' do
  it 'uses opts.speed and a single generated voice reference for OmniVoice' do
    ref_text = 'This reference sentence is long enough to establish a stable audiobook voice.'
    page = Audiobook::Page.new(1, [
      Audiobook::Paragraph.new([
        Audiobook::Sentence.new(ref_text)
      ])
    ])
    book = instance_double(Audiobook::Book, metadata: {}, pages: [page])
    runner = Audiobook::Runner.new(book, nil, SymMash.new(speed: '1.25'))

    Dir.mktmpdir do |dir|
      expect(TTS).to receive(:synthesize).with(
        text:     ref_text,
        lang:     'en',
        out_path: kind_of(String),
        speed:    1.25,
        instruct: Audiobook::Runner::DEFAULT_VOICE_INSTRUCT
      ) do |out_path:, **_kwargs|
        File.write(out_path, 'wav')
      end

      options = runner.send(:tts_options, dir)

      expect(options[:speed]).to eq(1.25)
      expect(options[:ref_text]).to eq(ref_text)
      expect(File).to exist(options[:speaker_wav])
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

  it 'passes TTS speed and voice reference to spoken page items' do
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
        speaker_wav: '/tmp/reference.wav',
        ref_text:    'Reference voice.'
      ) do |out_path:, **_kwargs|
        File.write(out_path, 'wav')
      end

      page.to_wav(
        dir, '0001',
        lang: 'en',
        tts_options: {
          speed:       1.25,
          speaker_wav: '/tmp/reference.wav',
          ref_text:    'Reference voice.',
        }
      )
    end
  end
end
