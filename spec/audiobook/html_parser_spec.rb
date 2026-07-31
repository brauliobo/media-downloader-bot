require 'spec_helper'

RSpec.describe Audiobook::Parsers::Html do
  def with_html(content, encoding: Encoding::UTF_8)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'book.html')
      File.binwrite(path, content.encode(encoding))
      yield path
    end
  end

  it 'extracts semantic HTML without navigation noise' do
    with_html('<title>Book</title><nav>Skip me</nav><h1>Chapter</h1><p>Hello <b>world</b>.</p>') do |path|
      data = described_class.extract_data(path)

      expect(data.metadata.title).to eq('Book')
      expect(data.content.lines.map(&:text)).to eq(['Chapter', 'Hello world.'])
      expect(data.content.lines.map(&:font_size)).to eq([24, 12])
    end
  end

  it 'uses structured comment blocks for malformed legacy markup and appends footnotes once' do
    html = <<~HTML
      <div class="discourse_title">A&#x301;nanda</div>
      <p class="Para_Indent"><!-- block a=1 type=paragraph --><center>Legacy text.</center><!-- /block --></p>
      <p class="Para_Footnote">(1) A note.</p>
    HTML
    opts = SymMash.new(
      html_title_selector: '.discourse_title', html_block_comments: true,
      html_language: 'en'
    )

    with_html(html) do |path|
      data = described_class.extract_data(path, opts: opts)

      expect(data.metadata.title).to eq("A\u0301nanda".unicode_normalize(:nfc))
      expect(data.content.lines.map(&:text)).to eq([
        "A\u0301nanda".unicode_normalize(:nfc), 'Legacy text.', 'Footnote 1. A note.'
      ])
    end
  end

  it 'uses an explicit localized title for metadata and structured narration' do
    opts = SymMash.new(html_title: 'Título traduzido', html_block_comments: true)

    with_html('<h1>English title</h1><p><!-- block type=paragraph -->Body.<!-- /block --></p>') do |path|
      data = described_class.extract_data(path, opts: opts)

      expect(data.metadata.title).to eq('Título traduzido')
      expect(data.content.lines.map(&:text)).to eq(['Título traduzido', 'Body.'])
    end
  end

  it 'preserves major and minor EWPRS subheadings as sections' do
    html = <<~HTML
      <div class="discourse_title">Discourse</div>
      <p class="Para_Major_Heading"><!-- block type=paragraph -->A Major Section Heading With More Than Ten Words That Remains Structural<!-- /block --></p>
      <p class="plain"><!-- block type=paragraph -->Section body.<!-- /block --></p>
      <p class="Para_Minor_Heading"><!-- block type=paragraph -->Minor Section<!-- /block --></p>
      <p class="plain"><!-- block type=paragraph -->More body.<!-- /block --></p>
    HTML
    opts = SymMash.new(
      html_title_selector: '.discourse_title', html_block_comments: true,
      html_language: 'en'
    )

    with_html(html) do |path|
      book = Audiobook::Book.from_input(path, opts: opts)
      sections = book.items.grep(Audiobook::Section)

      expect(sections.map { |section| [section.text, section.level] }).to eq([
        ['A Major Section Heading With More Than Ten Words That Remains Structural', 1],
        ['Minor Section', 2],
      ])

      yaml = File.join(File.dirname(path), 'book.yml')
      book.write(yaml)
      restored = Audiobook::Book.from_input(yaml, opts: opts)
      expect(restored.items.grep(Audiobook::Section).map(&:level)).to eq([1, 2])
    end
  end

  it 'falls back to Windows-1252 and normalizes legacy punctuation' do
    with_html("<p>It\x92s readable.</p>".b, encoding: Encoding::ASCII_8BIT) do |path|
      data = described_class.extract_data(path)

      expect(data.content.lines.first.text).to eq('It’s readable.')
    end
  end

  it 'dispatches HTML inputs through Book' do
    with_html('<h1>Title</h1><p>A complete sentence.</p>') do |path|
      book = Audiobook::Book.from_input(path, opts: SymMash.new(html_language: 'en'))

      expect(book.metadata.language).to eq('en')
      sentences = book.items.grep(Audiobook::Paragraph).flat_map(&:sentences).map(&:text)
      expect(sentences).to include('A complete sentence.')
    end
  end
end
