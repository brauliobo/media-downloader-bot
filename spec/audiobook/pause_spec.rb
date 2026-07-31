require 'spec_helper'

RSpec.describe 'Audiobook pause assembly' do
  it 'uses the paragraph pause before its first sentence and sentence pause thereafter' do
    Dir.mktmpdir('paragraph-pause-spec-') do |dir|
      first     = Audiobook::Sentence.new('First sentence.')
      second    = Audiobook::Sentence.new('Second sentence.')
      paragraph = Audiobook::Paragraph.new([first, second])
      paragraph.dir = dir
      paragraph.idx = '1'
      paragraph.lang = 'en'
      paragraph.tts_options = {}
      first_wav = File.join(dir, 'first.wav')
      second_wav = File.join(dir, 'second.wav')
      allow(first).to receive(:to_wav).and_return(first_wav)
      allow(second).to receive(:to_wav).and_return(second_wav)
      paragraph_pause = File.join(dir, 'paragraph-pause.wav')
      sentence_pause = File.join(dir, 'sentence-pause.wav')
      expect(Audiobook::AudioFiles).to receive(:pause)
        .with(Audiobook::Pauses::PARAGRAPH, dir).and_return(paragraph_pause)
      expect(second).to receive(:pause_file).with(dir).and_return(sentence_pause)
      expect(Zipper).to receive(:concat_audio).with(
        [paragraph_pause, first_wav, sentence_pause, second_wav],
        File.join(dir, 'para_1.wav')
      )

      paragraph.to_wav
    end
  end
end
