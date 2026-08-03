require 'spec_helper'
require_relative '../../../lib/audiobook/ewprs'

RSpec.describe Audiobook::Ewprs::Batch do
  Entry = Struct.new(:kind, :title, :path, :info, :sources, :chapters, keyword_init: true) do
    def slug = title.downcase.tr(' ', '_')
  end

  let(:output) { Dir.mktmpdir('ewprs-batch-') }
  let(:catalog) { double(parse_options: SymMash.new, language: 'en', language_name: 'English') }
  let(:topic) { {forum_topic_id: 2721, name: 'English Audiobooks'} }
  let(:entries) do
    %w[First Second Third].map do |title|
      Entry.new(kind: :discourse, title: title, path: title, info: nil, sources: [], chapters: nil)
    end
  end

  after { FileUtils.remove_entry(output) if Dir.exist?(output) }

  it 'publishes in catalog order while generation workers finish out of order' do
    published = []
    batch = described_class.new(
      catalog: catalog, output: output, jobs: 3, manager: double, chat_id: -100123,
      topic: topic, apply: true, stdout: StringIO.new, stderr: StringIO.new
    )
    delays = {'First' => 0.06, 'Second' => 0.03, 'Third' => 0.01}
    allow(batch).to receive(:generate_entry) do |entry|
      sleep delays.fetch(entry.title)
      {audio: File.join(output, entry.slug), chapter_count: nil}
    end
    allow(batch).to receive(:upload_entry) { |entry, *| published << entry.title }

    batch.run(discourses: entries, books: [])

    expect(published).to eq(%w[First Second Third])
  end

  it 'skips generation and publication for checkpointed entries' do
    batch = described_class.new(catalog: catalog, output: output, jobs: 5)
    batch.record(entries.first, message_id: 123)
    resumed = described_class.new(
      catalog: catalog, output: output, jobs: 5, manager: double, chat_id: -100123,
      topic: topic, apply: true, stdout: StringIO.new, stderr: StringIO.new
    )
    expect(resumed).not_to receive(:generate_entry)
    expect(resumed).not_to receive(:upload_entry)

    result = resumed.run(discourses: [entries.first], books: [])

    expect(result[:published]).to eq(1)
  end

  it 'edits published audio and checkpoints the installed audio hash' do
    audio = File.join(output, 'first.m4a')
    File.write(audio, 'replacement audio')
    allow(Prober).to receive(:for).with(audio).and_return(double(format: double(duration: 12.4)))
    manager = double
    expect(manager).to receive(:edit_generated_message).with(
      hash_including(chat_id: -100123, message_id: 123, audio_path: audio, duration: 12)
    ).and_return(message_id: 123, remote_id: 'replacement-remote')

    batch = described_class.new(catalog: catalog, output: output)
    batch.record(entries.first, message_id: 123, remote_id: 'original-remote')
    editor = described_class.new(
      catalog: catalog, output: output, jobs: 1, manager: manager, chat_id: -100123,
      topic: topic, apply: true, edit: true, stdout: StringIO.new, stderr: StringIO.new
    )

    result = editor.run(discourses: [entries.first], books: [])
    record = editor.published.fetch('discourse:first')

    expect(result[:edited]).to eq(1)
    expect(record).to include(
      operation: 'edit', message_id: 123, remote_id: 'replacement-remote',
      audio_sha256: Digest::SHA256.file(audio).hexdigest
    )

    resumed = described_class.new(
      catalog: catalog, output: output, jobs: 1, manager: manager, chat_id: -100123,
      topic: topic, apply: true, edit: true, regenerate: true, stdout: StringIO.new, stderr: StringIO.new
    )
    File.write(audio, 'regenerated audio')
    expect(resumed).not_to receive(:generate_entry)
    expect(manager).not_to receive(:edit_generated_message)
    expect(resumed.run(discourses: [entries.first], books: [])[:edited]).to eq(0)
  end

  it 'regenerates audio before editing when requested' do
    audio = File.join(output, 'first.m4a')
    File.write(audio, 'old audio')
    allow(Prober).to receive(:for).with(audio).and_return(double(format: double(duration: 12.4)))
    manager = double
    expect(manager).to receive(:edit_generated_message).and_return(
      message_id: 123, remote_id: 'replacement-remote'
    )
    batch = described_class.new(
      catalog: catalog, output: output, jobs: 1, manager: manager, chat_id: -100123,
      topic: topic, apply: true, edit: true, regenerate: true, stdout: StringIO.new, stderr: StringIO.new
    )
    batch.record(entries.first, message_id: 123)
    expect(batch).to receive(:generate_entry).with(entries.first, force: true) do
      File.write(audio, 'regenerated audio')
      {audio: audio, chapter_count: nil}
    end

    batch.run(discourses: [entries.first], books: [])

    expect(batch.published.fetch('discourse:first')[:audio_sha256]).to eq(
      Digest::SHA256.file(audio).hexdigest
    )
  end

  it 'does not publish entries after a failed catalog position' do
    published = []
    batch = described_class.new(
      catalog: catalog, output: output, jobs: 3, manager: double, chat_id: -100123,
      topic: topic, apply: true, stdout: StringIO.new, stderr: StringIO.new
    )
    allow(batch).to receive(:generate_entry) do |entry|
      raise 'failed generation' if entry.title == 'Second'

      {audio: File.join(output, entry.slug), chapter_count: nil}
    end
    allow(batch).to receive(:upload_entry) { |entry, *| published << entry.title }

    expect { batch.run(discourses: entries, books: []) }.to raise_error('failed generation')
    expect(published).to eq(['First'])
  end

  it 'omits duration from publication captions' do
    batch = described_class.new(catalog: catalog, output: output)

    caption = batch.send(:caption, entries.first, 62, nil)

    expect(caption).to include("First\nP. R. Sarkar", 'Language: English')
    expect(caption).not_to include('Duration:')
  end

  it 'labels Portuguese publications from the catalog language' do
    entry = Entry.new(
      kind: :discourse, title: 'Primeiro', path: 'first', info: '1969, Ranchi',
      sources: ['Ánanda Vacanámrtam Parte 31'], chapters: nil
    )
    allow(catalog).to receive(:language_name).and_return('Portuguese')
    allow(catalog).to receive(:language).and_return('pt')
    batch = described_class.new(catalog: catalog, output: output)

    expect(batch.send(:caption, entry, 62, nil)).to eq(
      "Primeiro\nP. R. Sarkar\nTipo: Discurso\nData/local: 1969, Ranchi\n" \
      "Publicado em: Ánanda Vacanámrtam Parte 31\nIdioma: Português"
    )
  end

  it 'stages uploads outside the persistent output directory' do
    upload_dir = Dir.mktmpdir('ewprs-upload-')
    audio      = File.join(output, 'first.m4a')
    File.write(audio, 'audio')
    allow(Prober).to receive(:for).with(audio).and_return(double(format: double(duration: 12.4)))
    manager = double
    expect(manager).to receive(:upload_generated_media) do |params|
      expect(params[:audio_path]).to eq(File.join(upload_dir, 'first.m4a'))
      expect(File.read(params[:audio_path])).to eq('audio')
      {message_id: 123, remote_id: 'remote'}
    end
    batch = described_class.new(
      catalog: catalog, output: output, upload_dir: upload_dir, manager: manager, chat_id: -100123,
      topic: topic, apply: true, stdout: StringIO.new
    )

    batch.send(:upload_entry, entries.first, audio, nil, 1, 1)

    expect(File).to exist(audio)
    expect(File).not_to exist(File.join(upload_dir, 'first.m4a'))
  ensure
    FileUtils.remove_entry(upload_dir) if upload_dir && Dir.exist?(upload_dir)
  end

  it 'joins discourse chapters with the configured audiobook boundary' do
    book_entry = Entry.new(
      kind: :book, title: 'Collected Discourses', path: 'book', info: nil,
      sources: [], chapters: []
    )
    chapter_entries = entries.first(2)
    chapters = chapter_entries.map do |entry|
      Audiobook::Chapter.new(title: entry.title, audio: File.join(output, "#{entry.slug}.m4a"))
    end
    allow(catalog).to receive(:chapter_discourses).with(book_entry).and_return(chapter_entries)
    batch = described_class.new(catalog: catalog, output: output)
    allow(batch).to receive(:audiobook_chapter).and_return(*chapters)
    output_audio = File.join(output, 'book-collected_discourses.m4a')
    expect(Audiobook::Chapter).to receive(:join).with(chapters, output_audio)

    expect(batch.send(:generate_book, book_entry, force: true)).to eq([output_audio, 2])
  end

  it 'nests parsed EWPRS sections in their discourse chapter' do
    section = Audiobook::Section.new('Subheading', level: 2)
    book = instance_double(Audiobook::Book, items: [Audiobook::Heading.new('Title'), section])
    batch = described_class.new(catalog: catalog, output: output)
    allow(batch).to receive(:generate_discourse).with(entries.first).and_return(
      File.join(output, 'first.m4a')
    )
    allow(batch).to receive(:cached_discourse_book).with(entries.first).and_return(book)

    chapter = batch.send(:audiobook_chapter, entries.first)

    expect(chapter.title).to eq('First')
    expect(chapter.sections).to eq([section])
  end
end
