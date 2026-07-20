require 'spec_helper'

RSpec.describe TextHelpers do
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
