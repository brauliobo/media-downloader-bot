require 'rails_helper'

RSpec.describe Audiobook::Publication do
  it 'skips dotted table-of-contents pages when choosing metadata pages' do
    toc   = (1..8).map { |i| "Chapter #{i} #{'.' * 20} #{i}" }
    pages = [1, 2, 3, 4]
    texts = {
      1 => ['Este Livro é Dedicado a Todos os que Sofrem'],
      2 => toc,
      3 => ['Se nunca tinha ouvido falar no MMS antes, espero que não pense que este livro é sobre mais um suplemento.'],
      4 => ['Autor: James V. Humble (Jim Humble)', 'Tradução para Português'],
    }

    expect(described_class.select_pages(pages, texts)).to eq([1, 3, 4])
    expect(described_class.toc_like?(toc)).to eq(true)
    expect(described_class.toc_like?(texts[1])).to eq(false)
    expect(described_class.toc_like?(
      ['1. ACERCA DESTE LIVRO ...................................................................................... 1'] * 6
    )).to eq(true)
  end

  it 'falls back to the opening pages when every scanned page looks like a TOC' do
    toc   = (1..8).map { |i| "Chapter #{i} #{'.' * 20} #{i}" }
    pages = [1, 2, 3, 4, 5, 6]
    texts = pages.index_with { toc }

    expect(described_class.select_pages(pages, texts)).to eq([1, 2, 3, 4, 5])
  end
end
