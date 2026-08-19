require 'spec_helper'
require_relative '../../lib/audiobook/book'

RSpec.describe Audiobook::Book do
  describe 'language options' do
    it 'uses alang as the source-language override' do
      expect(Language).not_to receive(:detect)
      expect(described_class.detect_language('/does/not/exist.pdf', opts: SymMash.new(alang: 'pt'))).to eq('pt')
    end

    it 'treats lang= as the speech target, not the source' do
      opts = SymMash.new(lang: 'pt')
      Processors::Base.normalize_options(opts)

      expect(described_class.source_language(opts)).to be_nil
      expect(described_class.speech_language(opts)).to eq('pt')
    end
  end

  describe 'translation' do
    def english_book_data
      SymMash.new(
        metadata: {page_count: 1, language: 'en'},
        opts:     {includeall: true},
        content:  {
          lines: [
            {text: 'Chapter One', font_size: 18, page: 1, section_level: 1},
            {text: 'Hello world.', font_size: 12, page: 1},
            {text: 'Another sentence.', font_size: 12, page: 1},
          ],
          images: [],
        },
      )
    end

    before do
      allow(Translator).to receive(:translate) do |text, from:, to:|
        mapped = Array(text).map { |line| "PT(#{from}->#{to}):#{line}" }
        text.is_a?(Array) ? mapped : mapped.first
      end
    end

    it 'translates every sentence to lang=' do
      book = described_class.new(data: english_book_data, opts: SymMash.new(lang: 'pt', includeall: true))

      expect(book.pages.flat_map(&:all_sentences).map(&:text)).to contain_exactly(
        'PT(en->pt):Chapter One', 'PT(en->pt):Hello world.', 'PT(en->pt):Another sentence.'
      )
      expect(book.metadata.language).to eq('pt')
      expect(book.translated).to be(true)
      expect(Translator).to have_received(:translate).with(
        contain_exactly('Chapter One', 'Hello world.', 'Another sentence.'),
        from: 'en', to: 'pt'
      )
    end

    it 'translates every YAML sentence to slang=' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'book.yml')
        File.write(path, YAML.dump(
          'language' => 'en',
          'pages' => [{
            'page' => {
              'number' => 1,
              'items' => [
                {'heading' => {'text' => 'Title'}},
                {'paragraph' => {'sentences' => [
                  {'text' => 'First sentence.'},
                  {'text' => 'Second sentence.', 'references' => [
                    {'reference' => {'id' => '1', 'sentences' => [{'text' => 'A footnote.'}]}}
                  ]},
                ]}},
              ],
            },
          }],
        ))
        book = described_class.from_yaml(path, opts: SymMash.new(slang: 'pt'))

        expect(book.pages.flat_map(&:all_sentences).map(&:text)).to contain_exactly(
          'PT(en->pt):Title', 'PT(en->pt):First sentence.',
          'PT(en->pt):Second sentence.', 'PT(en->pt):A footnote.'
        )
        expect(book.metadata.language).to eq('pt')
      end
    end
  end

  it 'keeps page boundaries when fewer than three PDF pages are selected' do
    path = File.expand_path('../fixtures/image-text-handler.pdf', __dir__)
    book = described_class.from_input(path, opts: SymMash.new(pages: '2'))

    expect(book.pages.map(&:number)).to eq([2])
    expect(book.pages.first.all_sentences.map(&:text)).to include('DADOS DE COPYRIGHT')
  end

  it 'splits translated CJK paragraph text before audiobook generation' do
    line = Audiobook::Line.new('第一句。 第二句！第三句？', font_size: 12, page_number: 1)

    items = Audiobook::Paragraph::Factory.create_items_from_lines([line], 1)

    expect(items.first[:item].sentences.map(&:text)).to eq(['第一句。', '第二句！', '第三句？'])
  end

  it 'applies the Chinese sentence limit to embedded-language lines' do
    text = 'Vásáḿsi jiirńani yathá viháya naváni grhńáti naro’paráńi; ' \
      'Tathá shariiráni viháya jiirńányáni saḿyáti naváni dehii.'
    data = SymMash.new(
      metadata: {language: 'zh'},
      opts:     {includeall: true},
      content:  {lines: [{text: text, language: 'sa', font_size: 12, page: 1}], images: []}
    )

    book = described_class.new(data: data)
    sentences = book.pages.first.all_sentences.map(&:text)

    expect(sentences.map(&:length).max).to be <= described_class::CHINESE_MAX_SENTENCE_CHARS
    expect(sentences.join(' ')).to eq(text)
  end

  describe '.from_yaml' do
    it 'loads only requested pages while preserving their source numbers' do
      data = {
        'pages' => 3.times.map do |index|
          { 'page' => { 'number' => index + 1, 'items' => [
            { 'paragraph' => { 'sentences' => [{ 'text' => "Page #{index + 1}." }] } },
          ] } }
        end,
      }

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'book.yml')
        File.write(path, YAML.dump(data))
        book = described_class.from_yaml(path, opts: SymMash.new(pages: '1,3'))

        expect(book.pages.map(&:number)).to eq([1, 3])
        expect(book.pages.flat_map(&:all_sentences).map(&:text)).to eq(['Page 1.', 'Page 3.'])
      end
    end

    it 'removes repeated multi-sentence footers from pages and references' do
      data = {
        'language' => 'pt',
        'pages' => %w[One Two Three Four].map.with_index do |word, index|
          footer = [
            { 'text' => 'All rights reserved.' },
            { 'text' => 'No part of this publication may be reproduced.' },
          ]
          items = [
            { 'paragraph' => { 'sentences' => [{ 'text' => "Unique body text #{word}." }] } },
            { 'paragraph' => { 'sentences' => footer } },
          ]
          if index == 3
            items.pop
            joined_footer = [{ 'text' => footer.map { |sentence| sentence['text'] }.join(' ') }]
            items.first['paragraph']['sentences'].first['references'] = [
              { 'reference' => { 'id' => '1', 'sentences' => joined_footer } },
            ]
          end
          { 'page' => { 'number' => index + 1, 'items' => items } }
        end,
      }

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'book.yml')
        File.write(path, YAML.dump(data))
        book = described_class.from_yaml(path)
        spoken = book.pages.flat_map(&:all_sentences).map(&:text)

        expect(spoken).to contain_exactly(
          'Unique body text One.', 'Unique body text Two.', 'Unique body text Three.', 'Unique body text Four.'
        )
      end
    end

    it 'keeps repeated page boundaries when includeall is enabled' do
      data = {
        'pages' => 3.times.map do |index|
          { 'page' => { 'number' => index + 1, 'items' => [
            { 'paragraph' => { 'sentences' => [{ 'text' => 'Repeated footer.' }] } },
          ] } }
        end,
      }

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'book.yml')
        File.write(path, YAML.dump(data))
        book = described_class.from_yaml(path, opts: SymMash.new(includeall: true))

        expect(book.pages.flat_map(&:all_sentences).map(&:text)).to eq(['Repeated footer.'] * 3)
      end
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
