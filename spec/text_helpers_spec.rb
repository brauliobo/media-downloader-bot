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

    it 'leaves decimals and thousands separators alone' do
      expect(described_class.strip_inline_markers('mais de 10.000 e-mails')).to eq(['mais de 10.000 e-mails', []])
      expect(described_class.strip_inline_markers('over 195,000 indictments')).to eq(['over 195,000 indictments', []])
      expect(described_class.strip_inline_markers('CDD-299.93 índices')).to eq(['CDD-299.93 índices', []])
    end

    it 'takes a marker off a closing curly quote' do
      expect(described_class.strip_inline_markers('está acontecendo.”1')).to eq(['está acontecendo.”', ['1']])
    end

    it 'takes a call that closes the sentence off the number before it' do
      expect(described_class.strip_inline_markers('her experiences in 2006.1')).to eq(
        ['her experiences in 2006.', ['1']]
      )
    end

    it 'reads markers tagged from glyph geometry without guessing' do
      expect(described_class.strip_inline_markers("no ano de 2010#{described_class.reference_marker(1)},")).to eq(
        ['no ano de 2010,', ['1']]
      )
    end
  end

  describe '.marker_line?' do
    it 'recognises a line holding only footnote markers' do
      expect(described_class.marker_line?('1')).to be(true)
      expect(described_class.marker_line?('1 2')).to be(true)
      expect(described_class.marker_line?('3.')).to be(true)
      expect(described_class.marker_line?('1. O Ciclo das Políticas')).to be(false)
    end
  end

  describe '.strip_toc_leaders' do
    it 'removes leader runs and the page number they point at' do
      expect(described_class.strip_toc_leaders('H AITI ........................ 9')).to eq('H AITI')
      expect(described_class.strip_toc_leaders('Chapter I.……………The Hermetic Philosophy.'))
        .to eq('Chapter I. The Hermetic Philosophy.')
    end

    it 'leaves ordinary prose untouched' do
      expect(described_class.strip_toc_leaders('Wait... the answer is 42')).to eq('Wait... the answer is 42')
    end
  end

  describe '.join_pdf_lines' do
    it 'rejoins a word split by a soft hyphen' do
      expect(described_class.join_pdf_lines(["Su respuesta fue sim­", 'ple, me dijo'])).to eq('Su respuesta fue simple, me dijo')
    end

    it 'rejoins a word whose hyphen was spaced out by justification' do
      expect(described_class.join_pdf_lines(['que siga única -', 'mente sus conclusiones'])).to eq('que siga únicamente sus conclusiones')
    end

    it 'keeps a dash before a capitalised continuation' do
      expect(described_class.join_pdf_lines(['a solução -', 'Uma nova era'])).to eq('a solução - Uma nova era')
    end
  end
end
