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

  it 'uses the book cover as the audio thumbnail' do
    book = instance_double(Audiobook::Book)
    allow(book).to receive(:thumb).with(dir: 'tmp', base: 'book').and_return('/tmp/book-cover.jpg')
    allow(book).to receive(:metadata).and_return(SymMash.new(title: 'Book Title'))
    allow(Audiobook).to receive(:base_from_source).and_return('book')
    allow(Audiobook).to receive(:generate).and_return(
      SymMash.new(yaml: 'book.yml', audio: 'book.m4a', book: book)
    )
    allow(Prober).to receive(:for)

    uploads = Audiobook.generate_uploads('book.pdf', dir: 'tmp', stl: nil)

    expect(uploads.last.thumb).to eq('/tmp/book-cover.jpg')
    expect(uploads.last.mime).to eq('audio/aac')
    expect(uploads.last.fn_out).to eq('book.m4a')
    expect(uploads.map { |upload| upload.info.title }.uniq).to eq(['Book Title'])
  end

  it 'uploads a translation PDF with the yaml and audiobook' do
    book = instance_double(Audiobook::Book)
    allow(book).to receive(:thumb).with(dir: 'tmp', base: 'book').and_return(nil)
    allow(book).to receive(:metadata).and_return(SymMash.new)
    allow(Audiobook).to receive(:base_from_source).and_return('book')
    allow(Audiobook).to receive(:generate).and_return(
      SymMash.new(yaml: 'book.yml', audio: 'book.m4a', translation_pdf: 'book.pt.pdf', book: book)
    )
    allow(Prober).to receive(:for)

    uploads = Audiobook.generate_uploads('book.pdf', dir: 'tmp', stl: nil)

    expect(uploads.map { |upload| [upload.fn_out, upload.mime] }).to eq([
      ['book.yml', 'application/x-yaml'],
      ['book.pt.pdf', 'application/pdf'],
      ['book.m4a', 'audio/aac'],
    ])
  end

  it 'writes a translation PDF next to the yaml for a translated PDF' do
    Dir.mktmpdir do |dir|
      path  = File.join(dir, 'book.pdf')
      audio = File.join(dir, 'book.aac')
      File.write(path, '%PDF-1.4')
      book = instance_double(Audiobook::Book, translated: true, metadata: {'language' => 'pt'})
      allow(Audiobook::Book).to receive(:from_input).and_return(book)
      allow(book).to receive(:write)
      allow(Audiobook::TextPdf).to receive(:generate).and_return(File.join(dir, 'book.pt.pdf'))
      allow(Audiobook::Runner).to receive(:new)
        .and_return(instance_double(Audiobook::Runner, process_to_audio: audio))

      result = Audiobook.generate(path, audio, opts: SymMash.new(lang: 'pt'))

      expect(Audiobook::TextPdf).to have_received(:generate).with(book, File.join(dir, 'book.pt.pdf'), stl: nil, source_pdf: path)
      expect(result.translation_pdf).to eq(File.join(dir, 'book.pt.pdf'))
    end
  end

  it 'does not write a translation PDF for a translated text file' do
    Dir.mktmpdir do |dir|
      path  = File.join(dir, 'book.txt')
      audio = File.join(dir, 'book.aac')
      File.write(path, 'Hello.')
      book = instance_double(Audiobook::Book, translated: true, metadata: {'language' => 'pt'})
      allow(Audiobook::Book).to receive(:from_input).and_return(book)
      allow(book).to receive(:write)
      allow(Audiobook::TextPdf).to receive(:generate)
      allow(Audiobook::Runner).to receive(:new)
        .and_return(instance_double(Audiobook::Runner, process_to_audio: audio))

      result = Audiobook.generate(path, audio, opts: SymMash.new(lang: 'pt'))

      expect(Audiobook::TextPdf).not_to have_received(:generate)
      expect(result.translation_pdf).to be_nil
    end
  end

  it 'loads the top-level language written by the audiobook YAML format' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'book.yml')
      File.write(path, YAML.dump('language' => 'pt', 'pages' => []))

      expect(Audiobook::Book.from_yaml(path).metadata.language).to eq('pt')
    end
  end
end
