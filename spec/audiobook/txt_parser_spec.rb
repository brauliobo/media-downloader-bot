require 'spec_helper'

RSpec.describe Audiobook::Parsers::Txt do
  def with_txt(content, encoding: Encoding::UTF_8, name: 'book.txt')
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      encoded = content.encoding == Encoding::ASCII_8BIT ? content : content.encode(encoding)
      File.binwrite(path, encoded)
      yield path
    end
  end

  it 'splits blank-line paragraphs and hard-wrapped lines' do
    text = "CHAPTER ONE\n\nThis is the first paragraph that wraps\nacross two physical lines.\n\nSecond paragraph follows."

    with_txt(text) do |path|
      data = described_class.extract_data(path)

      expect(data.content.lines.map(&:text)).to eq([
        'CHAPTER ONE',
        'This is the first paragraph that wraps across two physical lines.',
        'Second paragraph follows.',
      ])
      expect(data.content.lines.map(&:font_size)).to eq([20, 12, 12])
    end
  end

  it 'treats single-newline files as one paragraph per line' do
    with_txt("First paragraph ends here.\nSecond paragraph starts here.") do |path|
      data = described_class.extract_data(path)

      expect(data.content.lines.map(&:text)).to eq([
        'First paragraph ends here.',
        'Second paragraph starts here.',
      ])
    end
  end

  it 'handles whitespace on blank separator lines' do
    with_txt("First paragraph.\n  \nSecond paragraph.") do |path|
      data = described_class.extract_data(path)

      expect(data.content.lines.map(&:text)).to eq(['First paragraph.', 'Second paragraph.'])
    end
  end

  it 'paginates by words and dispatches through Book' do
    page_one = "#{Array.new(300, 'word').join(' ')}."
    with_txt("#{page_one}\n\nNext page starts here.") do |path|
      data = described_class.extract_data(path, opts: SymMash.new(wpp: 300))
      expect(data.content.lines.map(&:page)).to eq([1, 2])
      expect(data.metadata.page_count).to eq(2)
      expect(data.opts.includeall).to eq(true)

      book = Audiobook::Book.from_input(path, opts: SymMash.new(alang: 'en', slang: 'en'))
      sentences = book.items.grep(Audiobook::Paragraph).flat_map(&:sentences).map(&:text)
      expect(sentences).to include('Next page starts here.')
      expect(book.metadata.language).to eq('en')
    end
  end

  it 'falls back to Windows-1252 encoding' do
    with_txt("It\x92s readable.".b, encoding: Encoding::ASCII_8BIT) do |path|
      data = described_class.extract_data(path)

      expect(data.content.lines.first.text).to eq('It’s readable.')
    end
  end

  it 'decodes BOM-marked UTF-16 text' do
    {
      Encoding::UTF_16LE => "\xFF\xFE".b,
      Encoding::UTF_16BE => "\xFE\xFF".b,
    }.each do |encoding, bom|
      content = bom + 'Readable UTF-16 text.'.encode(encoding).b
      with_txt(content, encoding: Encoding::ASCII_8BIT) do |path|
        data = described_class.extract_data(path)

        expect(data.content.lines.first.text).to eq('Readable UTF-16 text.')
      end
    end
  end

  it 'generates the audiobook and YAML sidecar through the shared runner' do
    with_txt('A complete audiobook sentence.') do |path|
      output = File.join(File.dirname(path), 'book.aac')
      opts = SymMash.new(alang: 'en', slang: 'en')
      runner = instance_double(Audiobook::Runner)
      allow(Audiobook::Runner).to receive(:new).and_return(runner)
      allow(runner).to receive(:process_to_audio).and_return(output)

      result = Audiobook.generate(path, output, opts: opts)

      expect(result.audio).to eq(output)
      expect(result.yaml).to eq(path.sub(/\.txt\z/i, '.yml'))
      expect(File).to exist(result.yaml)
      expect(YAML.safe_load(File.read(result.yaml)).dig('pages', 0, 'page', 'items')).not_to be_empty
      expect(File.read(path)).to eq('A complete audiobook sentence.')
      expect(runner).to have_received(:process_to_audio).with(output)
    end
  end
end
