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
      probe = SymMash.new(streams: [SymMash.new(codec_type: 'audio', sample_rate: 24_000)])
      allow(Prober).to receive(:for).with(first_audio).and_return(probe)
      pause = File.join(dir, 'pause.m4a')
      expect(Audiobook::AudioFiles).to receive(:pause).with(
        Audiobook::Pauses::CHAPTER,
        kind_of(String),
        sample_rate: 24_000,
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
