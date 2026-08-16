require 'spec_helper'

RSpec.describe TextHelpers do
  describe '.sentences_from_entries' do
    it 'groups typed words without mutating their entries' do
      words = [
        Subtitler::Subtitle::Word.new(text: 'Hello', start: 0, finish: 0.5),
        Subtitler::Subtitle::Word.new(text: '.', start: 0.5, finish: 0.6),
        Subtitler::Subtitle::Word.new(text: 'Again.', start: 1, finish: 2),
      ]
      entry = Subtitler::Subtitle::Entry.new(start: 0, finish: 2, words: words)

      sentences = described_class.sentences_from_entries([entry])

      expect(sentences.map(&:text)).to eq(['Hello .', 'Again.'])
      expect(sentences.map { |sentence| [sentence.start, sentence.finish] }).to eq([[0.0, 0.6], [1.0, 2.0]])
      expect(entry.words.map(&:text)).to eq(['Hello', '.', 'Again.'])
    end

    it 'rejects hash-shaped subtitle data' do
      expect { described_class.sentences_from_entries([{words: []}]) }
        .to raise_error(TypeError, /Subtitle::Entry/)
    end
  end

  describe '.strip_inline_markers' do
    it 'extracts adjacent superscript markers' do
      expect(described_class.strip_inline_markers('Troyes.1 and Eschenbach2')).to eq(
        ['Troyes. and Eschenbach', %w[1 2]]
      )
    end

    it 'preserves ordinary spaced numbers' do
      expect(described_class.strip_inline_markers('Livro 2')).to eq(['Livro 2', []])
    end

    it 'removes markers from footnote definitions without returning a citation' do
      expect(described_class.strip_inline_markers('Trieiro1 : Dictionary definition')).to eq(
        ['Trieiro : Dictionary definition', []]
      )
    end
  end
end
