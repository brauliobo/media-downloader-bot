require 'spec_helper'
require_relative '../../lib/audiobook/book'

RSpec.describe Audiobook::Book do
  describe '.detect_language' do
    it 'uses explicit language options before automatic detection' do
      expect(Language).not_to receive(:detect)

      lang = described_class.detect_language('/does/not/exist.pdf', opts: SymMash.new(slang: 'pt'))

      expect(lang).to eq('pt')
    end
  end

  it 'serializes word-number footnotes without nesting a reference in itself' do
    data = SymMash.new(
      metadata: { page_count: 1, language: 'pt' },
      opts:     { includeall: true },
      content:  {
        lines:  [
          { text: 'The main text ends here.', font_size: 12, page: 1, x: 40, y: 760, bottom_spacing: 20 },
          { text: 'The same trieiros1 path continued.', font_size: 12, page: 1, x: 40, y: 700, top_spacing: 20, bottom_spacing: 20 },
          { text: 'Another normal paragraph ends here.', font_size: 12, page: 1, x: 40, y: 600, top_spacing: 20, bottom_spacing: 20 },
          { text: 'Trieiro1 : Dictionary definition.', font_size: 8, page: 1, x: 40, y: 100, top_spacing: 20 },
        ],
        images: [],
      },
    )
    book = described_class.new(data: data, opts: SymMash.new)
    source = book.pages.first.items.grep(Audiobook::Paragraph).flat_map(&:sentences)
      .find { |sentence| sentence.text.include?('trieiros') }
    reference = source.references.first

    expect(reference.id).to eq('1')
    expect(reference.sentences.map(&:text)).to include('Trieiro : Dictionary definition.')
    expect(reference.sentences.flat_map(&:references)).not_to include(reference)

    Dir.mktmpdir do |dir|
      expect { book.write(File.join(dir, 'book.yml')) }.not_to raise_error
    end
  end

  it 'rejects cyclic footnote references before serializing the book' do
    first = Audiobook::Reference.new('1')
    second = Audiobook::Reference.new('2')
    main = Audiobook::Sentence.new('Main sentence.')
    first_note = Audiobook::Sentence.new('First note.')
    second_note = Audiobook::Sentence.new('Second note.')

    main.add_reference(first)
    first_note.add_reference(second)
    first.add_sentences(first_note)
    second_note.add_reference(first)
    second.add_sentences(second_note)

    expect(second.sentences).to be_empty

    book = described_class.allocate
    book.instance_variable_set(:@metadata, SymMash.new(language: 'pt'))
    book.instance_variable_set(:@lang, 'pt')
    book.instance_variable_set(
      :@pages,
      [Audiobook::Page.new(1, [Audiobook::Paragraph.new([main])])]
    )

    Dir.mktmpdir do |dir|
      expect { book.write(File.join(dir, 'book.yml')) }.not_to raise_error
    end
  end
end
