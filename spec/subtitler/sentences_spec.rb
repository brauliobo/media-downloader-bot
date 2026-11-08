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

    it 'cuts speech without punctuation at its longest pause (not within its first words) once it passes the word limit' do
      words = (0...100).map { |idx| Subtitler::Subtitle::Word.new(text: "w#{idx}", start: idx * 0.1 + (idx > 40 ? 3 : 0), finish: idx * 0.1 + 0.05 + (idx > 40 ? 3 : 0)) }
      entry = Subtitler::Subtitle::Entry.new(start: 0, finish: 103, words: words)

      sentences = described_class.from_entries([entry])

      expect(sentences.map { |sentence| sentence.words.size }).to eq([41, 59])
    end

    it 'cuts speech without punctuation at its longest pause once it runs past the duration limit, however few its words' do
      words = (0...40).map { |idx| Subtitler::Subtitle::Word.new(text: "w#{idx}", start: idx * 0.5 + (idx >= 30 ? 2 : 0), finish: idx * 0.5 + 0.4 + (idx >= 30 ? 2 : 0)) }
      entry = Subtitler::Subtitle::Entry.new(start: 0, finish: 22, words: words)

      sentences = described_class.from_entries([entry])

      expect(sentences.map { |sentence| sentence.words.size }).to eq([30, 10])
    end
  end
end
