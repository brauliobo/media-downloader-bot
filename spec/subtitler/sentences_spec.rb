require 'rails_helper'

RSpec.describe Subtitler::Sentences do
  describe '.from_entries' do
    it 'groups typed words without mutating their entries' do
      words = [
        Subtitler::Subtitle::Word.new(text: 'Hello', start: 0, finish: 0.5),
        Subtitler::Subtitle::Word.new(text: '.', start: 0.5, finish: 0.6),
        Subtitler::Subtitle::Word.new(text: 'Again.', start: 1, finish: 2),
      ]
      entry = Subtitler::Subtitle::Entry.new(start: 0, finish: 2, words: words)

      sentences = described_class.from_entries([entry])

      expect(sentences.map(&:text)).to eq(['Hello .', 'Again.'])
      expect(sentences.map { |sentence| [sentence.start, sentence.finish] }).to eq([[0.0, 0.6], [1.0, 2.0]])
      expect(entry.words.map(&:text)).to eq(['Hello', '.', 'Again.'])
    end
  end
end
