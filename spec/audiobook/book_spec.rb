require 'spec_helper'
require_relative '../../lib/audiobook/book'

RSpec.describe Audiobook::Book do
  describe 'publication sampling' do
    it 'skips dotted table-of-contents pages when choosing metadata pages' do
      toc   = (1..8).map { |i| "Chapter #{i} #{'.' * 20} #{i}" }
      pages = [1, 2, 3, 4]
      texts = {
        1 => ['Este Livro é Dedicado a Todos os que Sofrem'],
        2 => toc,
        3 => ['Se nunca tinha ouvido falar no MMS antes, espero que não pense que este livro é sobre mais um suplemento.'],
        4 => ['Autor: James V. Humble (Jim Humble)', 'Tradução para Português'],
      }

      expect(described_class.select_publication_pages(pages, texts)).to eq([1, 3, 4])
      expect(described_class.toc_like_page?(toc)).to eq(true)
      expect(described_class.toc_like_page?(texts[1])).to eq(false)
      expect(described_class.toc_like_page?(
        ['1. ACERCA DESTE LIVRO ...................................................................................... 1'] * 6
      )).to eq(true)
    end

    it 'falls back to the opening pages when every scanned page looks like a TOC' do
      toc   = (1..8).map { |i| "Chapter #{i} #{'.' * 20} #{i}" }
      pages = [1, 2, 3, 4, 5, 6]
      texts = pages.index_with { toc }

      expect(described_class.select_publication_pages(pages, texts)).to eq([1, 2, 3, 4, 5])
    end

    it 'samples past TOC pages and passes the filename into metadata detection' do
      toc  = (1..8).map { |i| "Chapter #{i} #{'.' * 20} #{i}" }
      data = SymMash.new(
        metadata: { title: 'A Solução Mineral', pdf_author: 'GENESIS 2 CHURCH', source_name: 'MMS Jim Humble', page_count: 4 },
        content:  {
          lines: [
            { text: 'Este Livro é Dedicado', font_size: 14, page: 1 },
            *toc.map { |text| { text: text, font_size: 10, page: 2 } },
            { text: 'Se nunca tinha ouvido falar no MMS antes, espero que não pense que este livro é sobre mais um suplemento.', font_size: 12, page: 3 },
            { text: 'Autor: James V. Humble (Jim Humble)', font_size: 12, page: 4 },
            { text: 'Tradução para Português', font_size: 12, page: 4 },
          ],
          images: [],
        },
      )
      seen = nil
      allow(Language).to receive(:book_metadata) do |input|
        seen = input
        { 'lang' => 'pt', 'title' => 'A Solução Mineral Mestre', 'author' => 'Jim Humble', 'gender' => 'male' }
      end

      book = described_class.new(data: data, opts: SymMash.new(source_base: 'MMS Jim Humble', includeall: true), translate: false)

      expect(seen).to include('Filename: MMS Jim Humble')
      expect(seen).to include('Autor: James V. Humble (Jim Humble)')
      expect(seen).to include('Tradução para Português')
      expect(seen).not_to include('Chapter 1')
      expect(book.author).to eq('Jim Humble')
      expect(book.language).to eq('pt')
    end
  end

  describe 'language options' do
    it 'uses alang as the source-language override' do
      expect(Language).not_to receive(:book_metadata)
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
      allow(Language).to receive(:book_metadata).and_return('title' => '', 'author' => '', 'gender' => 'male')
      allow(Translator).to receive(:translate) do |text, from:, to:|
        mapped = Array(text).map { |line| "PT(#{from}->#{to}):#{line}" }
        text.is_a?(Array) ? mapped : mapped.first
      end
    end

    it 'detects title and author then translates them' do
      allow(Language).to receive(:book_metadata).and_return(
        'title' => 'Hello Book', 'author' => 'Jane Doe', 'gender' => 'female'
      )
      book = described_class.new(data: english_book_data, opts: SymMash.new(lang: 'pt', includeall: true))

      expect(book.metadata.title).to eq('PT(en->pt):Hello Book')
      expect(book.metadata.author).to eq('PT(en->pt):Jane Doe')
      expect(book.author_gender).to eq('female')
    end

    it 'translates the book title and source filename' do
      data = english_book_data
      data.metadata.title = 'Hello Book'
      book = described_class.new(data: data, opts: SymMash.new(lang: 'pt', includeall: true, source_base: 'Hello Book'))

      expect(book.metadata.title).to eq('PT(en->pt):Hello Book')
      expect(book.translated_base).to eq('PT(en->pt):Hello Book')
    end

    it 'translates every sentence to lang=' do
      book = described_class.new(data: english_book_data, opts: SymMash.new(lang: 'pt', includeall: true))

      expect(book.pages.flat_map(&:all_sentences).map(&:text)).to contain_exactly(
        'PT(en->pt):Chapter One', 'PT(en->pt):Hello world.', 'PT(en->pt):Another sentence.'
      )
      expect(book.metadata.language).to eq('pt')
      expect(book.translated).to be(true)
      chapter = book.items.grep(Audiobook::Section).first || book.items.grep(Audiobook::Heading).first
      expect(chapter.font_size).to eq(18)
      expect(Translator).to have_received(:translate).with(
        contain_exactly('Chapter One', 'Hello world.', 'Another sentence.'),
        from: 'en', to: 'pt'
      )
    end

    it 'maps font size, bold, and alignment to chapters versus headings' do
      data = SymMash.new(
        metadata: {page_count: 1, language: 'en'},
        opts:     {includeall: true},
        content:  {
          lines: [
            {text: 'Book Title', font_size: 24, page: 1, bold: true, alignment: :center, x: 200, x_max: 400, page_width: 600},
            {text: 'Chapter One', font_size: 18, page: 1, bold: true, alignment: :center, x: 200, x_max: 400, page_width: 600},
            {text: 'A body paragraph that stays body because it has enough words in it.', font_size: 12, page: 1},
            {text: 'Another body paragraph continues the story with more words here.', font_size: 12, page: 1},
            {text: 'Chapter Two', font_size: 18, page: 1, bold: true, alignment: :center, x: 200, x_max: 400, page_width: 600},
            {text: 'More body text so twelve point remains the dominant size overall.', font_size: 12, page: 1},
            {text: 'A Short Heading', font_size: 12, page: 1, bold: true, alignment: :center, x: 180, x_max: 420, page_width: 600},
            {text: 'Final body paragraph after the inline heading with enough words.', font_size: 12, page: 1},
          ],
          images: [],
        },
      )
      book = described_class.new(data: data, opts: SymMash.new(includeall: true), translate: false)
      sections = book.items.grep(Audiobook::Section)

      expect(book.items.grep(Audiobook::Heading).map(&:text)).to include('Book Title')
      expect(sections.map { |section| [section.text, section.level] }).to include(
        ['Chapter One', 1], ['Chapter Two', 1], ['A Short Heading', 2]
      )
      expect(sections.find { |section| section.text == 'Chapter One' }.bold).to be(true)
      expect(sections.find { |section| section.text == 'Chapter One' }.alignment).to eq(:center)
    end

    it 'writes chapter and heading details into yaml and restores them' do
      data = SymMash.new(
        metadata: {page_count: 1, language: 'en'},
        opts:     {includeall: true},
        content:  {
          lines: [
            {text: 'Book Title', font_size: 24, page: 1, bold: true, alignment: :center, x: 200, x_max: 400, page_width: 600},
            {text: 'Chapter One', font_size: 18, page: 1, bold: true, alignment: :center, x: 200, x_max: 400, page_width: 600},
            {text: 'A body paragraph that stays body because it has enough words in it.', font_size: 12, page: 1},
            {text: 'Another body paragraph continues the story with more words here.', font_size: 12, page: 1},
            {text: 'Chapter Two', font_size: 18, page: 1, bold: true, alignment: :center, x: 200, x_max: 400, page_width: 600},
            {text: 'More body text so twelve point remains the dominant size overall.', font_size: 12, page: 1},
            {text: 'A Short Heading', font_size: 12, page: 1, bold: true, alignment: :center, x: 180, x_max: 420, page_width: 600},
            {text: 'Final body paragraph after the inline heading with enough words.', font_size: 12, page: 1},
          ],
          images: [],
        },
      )
      book = described_class.new(data: data, opts: SymMash.new(includeall: true), translate: false)

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'book.yml')
        book.write(path)
        yaml = YAML.safe_load(File.read(path))

        expect(yaml['font_roles']['body_size']).to eq(12.0)
        expect(yaml['outline'].map { |entry| [entry['text'], entry['role']] }).to include(
          ['Book Title', 'title'], ['Chapter One', 'chapter'], ['Chapter Two', 'chapter']
        )
        chapter = yaml['outline'].find { |entry| entry['text'] == 'Chapter Two' }
        expect(chapter['headings'].map { |entry| entry['text'] }).to include('A Short Heading')

        restored = described_class.from_yaml(path, opts: SymMash.new(includeall: true), translate: false)
        expect(restored.font_roles.body_size).to eq(12.0)
        expect(restored.items.grep(Audiobook::Section).map(&:role)).to include(:chapter)
        expect(restored.outline.map { |entry| entry['text'] }).to include('Chapter One')
      end
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

  it 'keeps headings and unique page lines on a short PDF' do
    path = File.expand_path('../fixtures/image-text-handler.pdf', __dir__)
    book = described_class.from_input(path, opts: SymMash.new(alang: 'pt'), translate: false)

    expect(book.pages.flat_map(&:all_sentences).map(&:text)).to include('DADOS DE COPYRIGHT')
  end

  it 'keeps headings and footers when translating' do
    allow(Translator).to receive(:translate) { |text, **| text }
    allow(Ocr).to receive(:transcribe).and_return(SymMash.new(content: {text: 'OCR cover dump'}))
    path = File.expand_path('../fixtures/image-text-handler.pdf', __dir__)
    book = described_class.from_input(path, opts: SymMash.new(alang: 'pt', lang: 'en'))

    expect(book.translated).to be(true)
    expect(book.pages.flat_map(&:all_sentences).map(&:text)).to include('DADOS DE COPYRIGHT')
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
