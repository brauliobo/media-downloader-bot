require 'rails_helper'

RSpec.describe Audiobook::Markers do
  describe '.strip_inline' do
    it 'extracts adjacent superscript markers' do
      expect(described_class.strip_inline('Troyes.1 and Eschenbach2')).to eq(
        ['Troyes. and Eschenbach', %w[1 2]]
      )
    end

    it 'preserves ordinary spaced numbers' do
      expect(described_class.strip_inline('Livro 2')).to eq(['Livro 2', []])
    end

    it 'removes markers from footnote definitions without returning a citation' do
      expect(described_class.strip_inline('Trieiro1 : Dictionary definition')).to eq(
        ['Trieiro : Dictionary definition', []]
      )
    end

    it 'leaves decimals and thousands separators alone' do
      expect(described_class.strip_inline('mais de 10.000 e-mails')).to eq(['mais de 10.000 e-mails', []])
      expect(described_class.strip_inline('over 195,000 indictments')).to eq(['over 195,000 indictments', []])
      expect(described_class.strip_inline('CDD-299.93 índices')).to eq(['CDD-299.93 índices', []])
    end

    it 'takes a marker off a closing curly quote' do
      expect(described_class.strip_inline('está acontecendo.”1')).to eq(['está acontecendo.”', ['1']])
    end

    it 'takes a call that closes the sentence off the number before it' do
      expect(described_class.strip_inline('her experiences in 2006.1')).to eq(
        ['her experiences in 2006.', ['1']]
      )
    end

    it 'leaves a digit that names a product or a gene alone' do
      expect(described_class.strip_inline('used with MMS1, CDS or CDH')).to eq(['used with MMS1, CDS or CDH', []])
      expect(described_class.strip_inline('the gene CRF2 regulates anxiety')).to eq(['the gene CRF2 regulates anxiety', []])
    end

    it 'takes a run of markers off the sentence they close' do
      expect(described_class.strip_inline('por emoções stressantes.17,18')).to eq(['por emoções stressantes.', %w[17 18]])
    end

    it 'reads markers tagged from glyph geometry without guessing' do
      expect(described_class.strip_inline("no ano de 2010#{described_class.wrap(1)},")).to eq(
        ['no ano de 2010,', ['1']]
      )
    end

    it 'takes a call off a question or an exclamation that ends the sentence' do
      expect(described_class.strip_inline('have testified?10')).to eq(['have testified?', ['10']])
      expect(described_class.strip_inline('gritou!7 e saiu')).to eq(['gritou! e saiu', ['7']])
    end

    it 'leaves a thousands group and a time of day alone' do
      expect(described_class.strip_inline('de 1.950')).to eq(['de 1.950', []])
      expect(described_class.strip_inline('às 3h30 da manhã')).to eq(['às 3h30 da manhã', []])
    end
  end

  describe '.wrap' do
    it 'tags each id of a marker run' do
      expect(described_class.wrap('17,18')).to eq('⟦17⟧⟦18⟧')
      expect(described_class.extract('stressantes.⟦17⟧⟦18⟧')).to eq(['stressantes.', %w[17 18]])
    end
  end

  describe '.line?' do
    it 'recognises a line holding only footnote markers' do
      expect(described_class.line?('1')).to be(true)
      expect(described_class.line?('1 2')).to be(true)
      expect(described_class.line?('3.')).to be(true)
      expect(described_class.line?('1. O Ciclo das Políticas')).to be(false)
    end
  end
end
