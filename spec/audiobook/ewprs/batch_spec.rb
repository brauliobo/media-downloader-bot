require 'rails_helper'

RSpec.describe Audiobook::Ewprs::Batch do
  let(:root)     { Dir.mktmpdir('ewprs-root-') }
  let(:output)   { Dir.mktmpdir('ewprs-batch-') }
  let(:language) { 'en' }
  let(:catalog)  { Audiobook::Ewprs::Catalog.new(root, language: language) }
  let(:manager)  { AudiobookHelpers::FakeChat.new }
  let(:topic)    { {forum_topic_id: 2721, name: 'English Audiobooks'} }
  let!(:tts)     { fake_tts }
  let(:first)    { catalog.discourses.find { |entry| entry.slug == 'first' } }
  let(:titles)   { %w[First Second Third] }
  let(:source)   { 'Ananda Vacanamrtam' }

  before { write_tree }

  after { [root, output].each { |dir| FileUtils.remove_entry(dir) if Dir.exist?(dir) } }

  def write_html(path, html)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, html)
  end

  def paragraph(text, css = 'Para_Indent') = "<p class=#{css}><!-- block type=paragraph -->#{text}<!-- /block --></p>"

  def write_tree(info: '1969, Ranchi')
    discourses = titles.map do |title|
      write_html(File.join(root, "HTML/Discourses/#{title.downcase}.html"),
                 "<div class=discourse_title>#{title}</div><div class=discourse_info>#{info}</div>" + paragraph("#{title} body."))
      "<div class=list_discourse_title><a href='../Discourses/#{title.downcase}.html'>#{title}</a></div>" \
        "<div>#{info}</div><div><a href='../Books/collected.html##{title.downcase}'>#{source}</a></div>"
    end
    write_html(File.join(root, 'HTML/Navigation/alphabetical.html'), discourses.join)
    chapters = titles.first(2).map { |title| "<a href='../Books/collected.html##{title.downcase}'>#{title}</a>" }.join
    write_html(File.join(root, 'HTML/Navigation/books_tocs.html'),
               "<div class=books_book_title_tocs><a href='../Books/collected.html'>Collected Discourses</a></div><div>#{chapters}</div>")
    write_html(File.join(root, 'HTML/Books/collected.html'), '<div class=book_title>Collected Discourses</div>')
  end

  def batch(**options)
    described_class.new(catalog: catalog, output: output, jobs: 3, manager: manager, chat_id: -100123, topic: topic,
                        apply: true, stdout: StringIO.new, stderr: StringIO.new, **options)
  end

  def generate(*entries) = batch(apply: false).run(discourses: entries, books: [])

  def audio = File.join(output, 'first.m4a')

  def sha = Digest::SHA256.file(audio).hexdigest

  it 'publishes in catalog order while generation workers finish out of order' do
    delays = {'First' => 0.6, 'Second' => 0.3, 'Third' => 0}
    tts.before = ->(call) { sleep delays.find { |title, _| call[:text].to_s.include?(title) }&.last.to_f }

    batch.run(discourses: catalog.discourses, books: [])

    expect(manager.titles).to eq(titles)
    expect(tts.narration.first[:text]).to include('Third')
  end

  it 'skips generation and publication for checkpointed entries' do
    batch.record(first, message_id: 123)

    result = batch.run(discourses: [first], books: [])

    expect(result[:published]).to eq(1)
    expect(tts.calls).to be_empty
    expect(manager.uploads).to be_empty
  end

  it 'edits published audio and checkpoints the installed audio hash' do
    batch.run(discourses: [first], books: [])
    editor = batch(edit: true)

    result = editor.run(discourses: [first], books: [])

    expect(result[:edited]).to eq(1)
    expect(manager.edits.sole).to include(chat_id: -100123, message_id: 101, audio_path: audio, duration: be_positive)
    expect(editor.published.fetch('discourse:first')).to include(
      operation: 'edit', title: 'First', message_id: 101, remote_id: 'edited-1', audio_sha256: sha
    )

    generated = tts.calls.size
    resumed = batch(edit: true, regenerate: true)
    expect(resumed.run(discourses: [first], books: [])[:edited]).to eq(0)
    expect([tts.calls.size, manager.edits.size]).to eq([generated, 1])
  end

  it 'skips edit entries without published message records' do
    generate(first)
    batch = batch(edit: true, edit_run_id: 'run')
    batch.record(first, message_id: 123)

    result = batch.run(discourses: catalog.discourses, books: [])

    expect(result.values_at(:edited, :published)).to eq([1, 1])
    expect(manager.edits.sole).to include(message_id: 123)
  end

  it 're-edits old checkpoints for a new edit run and resumes that run' do
    generate(first)
    previous = batch(edit: true, edit_run_id: 'old-run')
    previous.record(first, message_id: 123, remote_id: 'original-remote')
    previous.run(discourses: [first], books: [])
    generated = tts.calls.size

    batch(edit: true, regenerate: true, edit_run_id: 'new-run').run(discourses: [first], books: [])
    regenerated = tts.calls.size
    resumed = batch(edit: true, regenerate: true, edit_run_id: 'new-run').run(discourses: [first], books: [])

    expect(regenerated).to be > generated
    expect(manager.edits.size).to eq(2)
    expect([resumed[:edited], tts.calls.size]).to eq([0, regenerated])
  end

  it 'regenerates audio before editing when requested' do
    batch = batch(edit: true, regenerate: true)
    batch.record(first, message_id: 123)

    batch.run(discourses: [first], books: [])

    expect(tts.narration).not_to be_empty
    expect(manager.edits.sole).to include(message_id: 123)
    expect(batch.published.fetch('discourse:first')[:audio_sha256]).to eq(sha)
  end

  it 'does not publish entries after a failed catalog position' do
    allow(Kernel).to receive(:sleep)
    tts.before = ->(call) { raise 'failed generation' if call[:text].to_s.include?('Second') }

    expect { batch.run(discourses: catalog.discourses, books: []) }.to raise_error('failed generation')
    expect(manager.titles).to eq(['First'])
  end

  it 'describes the publication in the caption, without its duration' do
    batch.run(discourses: [first], books: [])

    caption = manager.uploads.sole[:text]
    expect(caption).to eq("First\nP. R. Sarkar\nType: Discourse\nDate/place: 1969, Ranchi\nPublished in: Ananda Vacanamrtam\nLanguage: English")
    expect(caption).not_to include('Duration:')
  end

  context 'with a Portuguese catalog' do
    let(:language) { 'pt' }
    let(:titles)   { %w[Primeiro Segundo Terceiro] }
    let(:source)   { 'Ánanda Vacanámrtam Parte 31' }

    it 'labels the publication from the catalog language' do
      batch.run(discourses: [catalog.discourses.first], books: [])

      expect(manager.uploads.sole[:text]).to eq(
        "Primeiro\nP. R. Sarkar\nTipo: Discurso\nData/local: 1969, Ranchi\n" \
        "Publicado em: Ánanda Vacanámrtam Parte 31\nIdioma: Português"
      )
    end
  end

  it 'stages uploads outside the persistent output directory' do
    upload_dir = Dir.mktmpdir('ewprs-upload-')

    batch(upload_dir: upload_dir).run(discourses: [first], books: [])

    expect(manager.uploads.sole).to include(audio_path: File.join(upload_dir, 'first.m4a'), staged: true)
    expect(File).to exist(audio)
    expect(File).not_to exist(File.join(upload_dir, 'first.m4a'))
  ensure
    FileUtils.remove_entry(upload_dir) if upload_dir && Dir.exist?(upload_dir)
  end

  it 'joins the chapters of a book from its mapped discourses' do
    book = catalog.books.sole
    stdout = StringIO.new

    batch(apply: false, stdout: stdout).run(discourses: [], books: [book])

    book_audio = File.join(output, 'book-collected.m4a')
    chapter_durations = %w[first second].map { |slug| Prober.for(File.join(output, "#{slug}.m4a")).format.duration.to_f }
    expect(stdout.string).to include('generated book: Collected Discourses (2/2 chapters)')
    expect(Prober.for(book_audio).format.duration.to_f).to be > chapter_durations.sum
  end

  it 'nests parsed EWPRS sections in their discourse chapter' do
    write_html(File.join(root, 'HTML/Discourses/first.html'),
               "<div class=discourse_title>First</div>#{paragraph('Subheading', 'Para_Minor_Heading')}#{paragraph('First body.')}")

    chapter = batch.send(:audiobook_chapter, first)

    expect(chapter.title).to eq('First')
    expect(chapter.sections.map(&:text)).to eq(['Subheading'])
  end
end
