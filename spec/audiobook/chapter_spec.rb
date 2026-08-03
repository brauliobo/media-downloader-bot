require 'spec_helper'

RSpec.describe Audiobook::Chapter do
  it 'keeps section pauses shorter than discourse chapter pauses' do
    expect(Audiobook::Pauses::SENTENCE).to be < Audiobook::Pauses::PARAGRAPH
    expect(Audiobook::Pauses::PARAGRAPH).to be < Audiobook::Pauses::SECTION
    expect(Audiobook::Pauses::SECTION).to be < Audiobook::Pauses::CHAPTER
  end

  it 'inserts a floor-matched pause between chapter audio files' do
    Dir.mktmpdir('chapter-spec-') do |dir|
      first_audio  = File.join(dir, 'first.m4a')
      second_audio = File.join(dir, 'second.m4a')
      output       = File.join(dir, 'book.m4a')
      File.write(first_audio, 'first')
      File.write(second_audio, 'second')
      sections = [Audiobook::Section.new('First section', level: 1)]
      chapters = [
        described_class.new(title: 'First', audio: first_audio, sections: sections),
        described_class.new(title: 'Second', audio: second_audio),
      ]
      format = {
        codec_name:        'aac',
        profile:           'HE-AAC',
        codec_tag_string:  'mp4a',
        mime_codec_string: 'mp4a.40.5',
        sample_fmt:        'fltp',
        sample_rate:       24_000,
        channels:          2,
        channel_layout:    'stereo',
        bits_per_sample:   0,
        extradata_size:    4,
        bit_rate:          32_004,
      }
      allow(Prober).to receive(:audio_format).with(first_audio).and_return(format)
      pause = File.join(dir, 'pause.m4a')
      expect(Audiobook::AudioFiles).to receive(:pause).with(
        Audiobook::Pauses::CHAPTER,
        kind_of(String),
        format: format,
        extension: '.m4a',
        amplitude: 0.001
      ).and_return(pause)
      expect(Zipper).to receive(:concat_audio).with([first_audio, pause, second_audio], output) do
        File.write(output, 'joined')
        output
      end

      expect(described_class.join(chapters, output, pause_amplitude: 0.001)).to eq(output)
      expect(chapters.first.sections).to eq(sections)
    end
  end
end
