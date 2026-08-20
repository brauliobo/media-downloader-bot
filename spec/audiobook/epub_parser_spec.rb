require 'spec_helper'

RSpec.describe Audiobook::Parsers::Epub do
  def build_epub(dir)
    oebps = File.join(dir, 'OEBPS')
    meta  = File.join(dir, 'META-INF')
    FileUtils.mkdir_p([oebps, meta])
    File.write(File.join(dir, 'mimetype'), 'application/epub+zip')
    File.write(File.join(meta, 'container.xml'), <<~XML)
      <?xml version="1.0"?>
      <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>
          <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles>
      </container>
    XML
    File.write(File.join(oebps, 'styles.css'), <<~CSS)
      .title { font-size: 24pt; font-weight: bold; text-align: center; }
      .chapter { font-size: 22pt; font-weight: bold; text-align: center; color: #112233; font-family: Georgia; }
      .heading { font-size: 16pt; font-weight: bold; }
      .body { font-size: 12pt; }
    CSS
    File.write(File.join(oebps, 'chapter.xhtml'), <<~XHTML)
      <?xml version="1.0" encoding="UTF-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml">
        <head><link rel="stylesheet" href="styles.css" type="text/css"/></head>
        <body>
          <p class="title">Book Title</p>
          <p class="chapter">Chapter One</p>
          <p class="heading">A Short Heading</p>
          <p class="body">A body paragraph that stays body because it has enough words in it.</p>
          <p class="body">Another body paragraph continues the story with more words here.</p>
          <p class="chapter">Chapter Two</p>
          <p class="body">More body text so twelve point remains the dominant size overall.</p>
          <p class="body">Final body paragraph after the heading with enough words to stay body.</p>
        </body>
      </html>
    XHTML
    File.write(File.join(oebps, 'content.opf'), <<~XML)
      <?xml version="1.0"?>
      <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="BookId">id1</dc:identifier>
          <dc:title>Test</dc:title>
          <dc:language>en</dc:language>
        </metadata>
        <manifest>
          <item id="css" href="styles.css" media-type="text/css"/>
          <item id="ch1" href="chapter.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine>
          <itemref idref="ch1"/>
        </spine>
      </package>
    XML
    epub = File.join(dir, 'book.epub')
    system('zip', '-q', '-X', '-r', epub, 'mimetype', 'META-INF', 'OEBPS', chdir: dir)
    epub
  end

  it 'maps EPUB CSS classes onto the generic line style' do
    Dir.mktmpdir do |dir|
      path = build_epub(dir)
      data = described_class.extract_data(path)
      chapter = data.content.lines.find { |line| line.text == 'Chapter One' }

      expect(chapter.text).to eq('Chapter One')
      expect(chapter.font_size).to eq(22)
      expect(chapter.bold).to be(true)
      expect(chapter.alignment).to eq(:center)
      expect(chapter.color).to eq('#112233')
      expect(chapter.font_name).to eq('Georgia')
    end
  end

  it 'classifies CSS-styled EPUB chapters through Book' do
    allow(Language).to receive(:book_metadata).and_return('title' => '', 'author' => '', 'gender' => 'male')

    Dir.mktmpdir do |dir|
      path = build_epub(dir)
      book = Audiobook::Book.from_input(path, opts: SymMash.new(includeall: true), translate: false)
      yaml_path = File.join(dir, 'book.yml')
      book.write(yaml_path)
      yaml = YAML.safe_load(File.read(yaml_path))

      expect(book.items.grep(Audiobook::Section).map(&:text)).to include('Chapter One', 'Chapter Two')
      expect(yaml['outline'].map { |entry| [entry['text'], entry['role']] }).to include(
        ['Chapter One', 'chapter'], ['Chapter Two', 'chapter']
      )
    end
  end
end
