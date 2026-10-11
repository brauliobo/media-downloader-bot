require 'rails_helper'

RSpec.describe 'Audiobook OCR language detection' do
  let(:dir) { Dir.mktmpdir('uploads-') }

  after { FileUtils.remove_entry dir }

  def source(name = 'book', ext: 'pdf')
    path = File.join(dir, "#{name}.#{ext}")
    ext == 'pdf' ? write_pdf(path, 'Hello world.') : File.write(path, 'Hello world.')
    path
  end

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
    asked = fake_llm(lang: 'pt')

    book = Audiobook::Book.new(data: image_book_data(1))

    expect(asked.sole).to include('portugues')
    expect(book.metadata.language).to eq('pt')
  end

  it 'OCRs only sample pages for detection and re-OCRs images with the detected language' do
    stub_const('Audiobook::Publication::SAMPLE_PAGES', 2)
    calls = []

    allow(Audiobook::OcrText).to receive(:transcribe) do |path, opts: nil, **_kwargs|
      calls << SymMash.new(path: path, lang: opts&.dig(:lang))
      "Texto portugues #{path}"
    end
    asked = fake_llm(lang: 'pt')

    Audiobook::Book.new(data: image_book_data(1, 2, 3))

    expect(asked.sole).to include('book.pdf#page=1', 'book.pdf#page=2')
    expect(asked.sole).not_to include('book.pdf#page=3')
    expect(calls.map(&:path).first(2)).to eq(['book.pdf#page=1', 'book.pdf#page=2'])
    expect(calls.first(2).map(&:lang)).to eq([nil, nil])
    expect(calls.drop(2).map(&:path)).to eq(['book.pdf#page=1', 'book.pdf#page=2', 'book.pdf#page=3'])
    expect(calls.drop(2).map(&:lang)).to eq(%w[pt pt pt])
  end

  it 'passes audiobook options to sampled OCR and adds detected language to final image OCR' do
    stub_const('Audiobook::Publication::SAMPLE_PAGES', 1)
    opts = SymMash.new(includeall: true)
    seen_opts = []

    allow(Audiobook::OcrText).to receive(:transcribe) do |_path, opts: nil, **_kwargs|
      seen_opts << opts
      'Texto portugues'
    end
    fake_llm(lang: 'pt')

    Audiobook::Book.new(data: image_book_data(1, 2), opts: opts)

    expect(seen_opts.first).to eq(opts)
    expect(seen_opts.drop(1).map { |seen| seen[:lang] }).to eq(%w[pt pt])
    expect(opts[:lang]).to be_nil
  end

  describe '.generate_uploads' do
    def uploads_of(source, **opts) = Audiobook.generate_uploads(source, dir: dir, stl: nil, opts: SymMash.new(opts))

    def names(uploads) = uploads.map { |upload| File.basename(upload.fn_out) }

    it 'returns only the yaml upload for onlyyml generation' do
      uploads = uploads_of(source(ext: 'txt'), onlyyml: 1)

      expect(names(uploads)).to eq(['book.yml'])
      expect(uploads.first.mime).to eq('application/x-yaml')
      expect(File).to exist(uploads.first.fn_out)
    end

    it 'attaches the cover thumb to onlyyml uploads' do
      uploads = uploads_of(source, onlyyml: 1)

      expect(uploads.size).to eq(1)
      expect(File).to exist(uploads.first.thumb)
    end

    it 'uses the book cover as the audio thumbnail and the detected title and author as its info' do
      fake_tts
      fake_llm(lang: 'pt', title: 'Book Title', author: 'Jane Austen')

      uploads = uploads_of(source)

      expect(names(uploads)).to eq(['book.yml', 'book.m4a'])
      expect(uploads.map(&:thumb).uniq.sole).to satisfy { |thumb| File.exist?(thumb) }
      expect(uploads.last.mime).to eq('audio/aac')
      expect(uploads.map { |upload| upload.info.title }.uniq).to eq(['Book Title'])
      expect(uploads.map { |upload| upload.info.uploader }).to eq(['', 'Jane Austen'])
      expect(uploads.last.oprobe.format.duration.to_f).to be_positive
    end

    context 'when the book is translated' do
      before do
        fake_tts
        fake_html_to_pdf
        fake_llm(lang: 'es', title: '32 motives', author: 'Mark Grenon')
        fake_translator('32 motives' => '32 motivos', 'Mark Grenon' => 'Mark Grenon')
      end

      it 'uploads the translation PDF with the yaml and the audiobook' do
        uploads = uploads_of(source('Reasons'), lang: 'pt')

        expect(uploads.map(&:mime)).to eq(%w[application/x-yaml application/pdf audio/aac])
        expect(uploads.map { |upload| File.exist?(upload.fn_out) }).to all(be(true))
        expect(uploads.map(&:thumb).uniq.size).to eq(1)
      end

      it 'names the uploads after the translated title and the author' do
        uploads = uploads_of(source('Reasons'), lang: 'pt')

        expect(names(uploads)).to eq(['32 motivos - Mark Grenon.yml', '32 motivos - Mark Grenon.pt.pdf', '32 motivos - Mark Grenon.m4a'])
        expect(uploads.map { |upload| upload.info.title }.uniq).to eq(['32 motivos'])
      end

      it 'names the uploads after the translated file name when the book has no title of its own' do
        fake_llm(lang: 'es')
        fake_translator('Adios' => 'Adeus a inflamacao')

        uploads = uploads_of(source('Adios'), lang: 'pt')

        expect(names(uploads)).to eq(['Adeus a inflamacao.yml', 'Adeus a inflamacao.pt.pdf', 'Adeus a inflamacao.m4a'])
        expect(uploads.map { |upload| upload.info.title }.uniq).to eq(['Adeus a inflamacao'])
      end
    end
  end

  describe '.generate' do
    before { fake_tts }

    def generate(path, **opts) = Audiobook.generate(path, File.join(dir, 'book.aac'), opts: SymMash.new(opts))

    it 'writes a translation PDF next to the yaml for a translated PDF' do
      fake_html_to_pdf
      fake_translator
      fake_llm(lang: 'en')

      result = generate(source, lang: 'pt')

      expect(result.translation_pdf).to eq(File.join(dir, 'book.pt.pdf'))
      expect(File).to exist(result.translation_pdf)
    end

    it 'does not write a translation PDF for a translated text file' do
      fake_translator
      fake_llm(lang: 'en')

      result = generate(source(ext: 'txt'), lang: 'pt')

      expect(result.translation_pdf).to be_nil
      expect(result.book.translated).to be(true)
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
