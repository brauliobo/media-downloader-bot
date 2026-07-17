require 'spec_helper'

RSpec.describe 'Audiobook OCR language detection' do
  def image_data(page)
    SymMash.new(image: true, page: page, path: "book.pdf#page=#{page}")
  end

  def image_book_data(*pages)
    SymMash.new(
      metadata: SymMash.new(page_count: pages.max),
      content: SymMash.new(lines: [], images: pages.map { |page| image_data(page) })
    )
  end

  it 'detects language from sampled image OCR text' do
    allow(Audiobook::OcrText).to receive(:transcribe).and_return('Texto em portugues da pagina escaneada.')

    allow(Language).to receive(:detect) do |paragraphs|
      expect(paragraphs.map(&:text).join("\n")).to include('portugues')
      'pt'
    end

    book = Audiobook::Book.new(data: image_book_data(1))

    expect(book.metadata.language).to eq('pt')
  end

  it 'OCRs only sample pages for detection and re-OCRs images with the detected language' do
    stub_const('Audiobook::Book::LANGUAGE_SAMPLE_PAGES', 2)
    calls = []

    allow(Audiobook::OcrText).to receive(:transcribe) do |path, opts: nil, **_kwargs|
      calls << SymMash.new(path: path, lang: opts&.dig(:lang))
      "Texto portugues #{path}"
    end

    allow(Language).to receive(:detect) do |paragraphs|
      sample = paragraphs.map(&:text).join("\n")
      expect(sample).to include('book.pdf#page=1')
      expect(sample).to include('book.pdf#page=2')
      expect(sample).not_to include('book.pdf#page=3')
      'pt'
    end

    Audiobook::Book.new(data: image_book_data(1, 2, 3))

    expect(calls.map(&:path).first(2)).to eq(['book.pdf#page=1', 'book.pdf#page=2'])
    expect(calls.first(2).map(&:lang)).to eq([nil, nil])
    expect(calls.drop(2).map(&:path)).to eq(['book.pdf#page=1', 'book.pdf#page=2', 'book.pdf#page=3'])
    expect(calls.drop(2).map(&:lang)).to eq(%w[pt pt pt])
  end

  it 'passes audiobook options to sampled OCR and adds detected language to final image OCR' do
    stub_const('Audiobook::Book::LANGUAGE_SAMPLE_PAGES', 1)
    opts = SymMash.new(includeall: true)
    seen_opts = []

    allow(Audiobook::OcrText).to receive(:transcribe) do |_path, opts: nil, **_kwargs|
      seen_opts << opts
      'Texto portugues'
    end
    allow(Language).to receive(:detect).and_return('pt')

    Audiobook::Book.new(data: image_book_data(1, 2), opts: opts)

    expect(seen_opts.first).to eq(opts)
    expect(seen_opts.drop(1).map { |seen| seen[:lang] }).to eq(%w[pt pt])
    expect(opts[:lang]).to be_nil
  end

  it 'returns only the yaml upload for onlyyml generation' do
    opts = SymMash.new(onlyyml: 1)
    allow(Audiobook).to receive(:generate).and_return(SymMash.new(yaml: 'book.yml'))

    uploads = Audiobook.generate_uploads('book.pdf', dir: 'tmp', stl: nil, opts: opts)

    expect(uploads.size).to eq(1)
    expect(uploads.first.fn_out).to eq('book.yml')
    expect(uploads.first.mime).to eq('application/x-yaml')
  end

  it 'loads the top-level language written by the audiobook YAML format' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'book.yml')
      File.write(path, YAML.dump('language' => 'pt', 'pages' => []))

      expect(Audiobook::Book.from_yaml(path).metadata.language).to eq('pt')
    end
  end
end
