require 'spec_helper'

RSpec.describe 'Heading extraction from PDF' do
  def fixture_path(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  it 'captures title paragraphs and the intro heading from headings.pdf' do
    book = Audiobook::Book.from_input(fixture_path('headings.pdf'), opts: SymMash.new(alang: 'pt'))
    items = book.pages.first.items

    texts = items.flat_map { |item| item.is_a?(Audiobook::Heading) ? [item.text] : item.sentences.map(&:text) }

    expect(texts).to include('HE - A CHAVE DO ENTENDIMENTO DA PSICOLOGIA MASCULINA')
    expect(texts).to include('INTRODUÇÃO')
    expect(texts.join(' ')).to include('AUTOR: ROBERT A.')
    expect(texts.join(' ')).to include('EDITORA: MERCURYO')
    expect(items.grep(Audiobook::Heading).map(&:text)).to include('INTRODUÇÃO')
  end

  it 'writes chapter and heading details from real PDFs into yaml' do
    allow(Language).to receive(:book_metadata).and_return('title' => '', 'author' => '', 'gender' => 'male')

    %w[headings.pdf image-text-handler.pdf page-paragraphs-merge.pdf].each do |name|
      book = Audiobook::Book.from_input(
        fixture_path(name),
        opts: SymMash.new(alang: 'pt', includeall: true),
        translate: false
      )

      Dir.mktmpdir do |dir|
        path = File.join(dir, "#{File.basename(name, '.pdf')}.yml")
        book.write(path)
        yaml = YAML.safe_load(File.read(path))

        expect(yaml).to have_key('font_roles')
        expect(yaml['font_roles']).to have_key('body_size')
        expect(yaml['pages']).to be_present
        expect(book.pages).not_to be_empty
        restored = Audiobook::Book.from_yaml(path, opts: SymMash.new(includeall: true), translate: false)
        expect(restored.pages.size).to eq(book.pages.size)
      end
    end

    headings = Audiobook::Book.from_input(
      fixture_path('headings.pdf'),
      opts: SymMash.new(alang: 'pt', includeall: true),
      translate: false
    )
    texts = headings.outline.flat_map { |entry| [entry['text'], *Array(entry['headings']).map { |heading| heading['text'] }] }
    expect(texts).to include('INTRODUÇÃO')
  end

end
