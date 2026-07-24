require 'spec_helper'
require_relative '../../lib/audiobook/ewprs_batch'

RSpec.describe Audiobook::EwprsBatch do
  Entry = Struct.new(:kind, :title, :path, :info, :sources, :chapters, keyword_init: true) do
    def slug = title.downcase.tr(' ', '_')
  end

  let(:output) { Dir.mktmpdir('ewprs-batch-') }
  let(:catalog) { double(parse_options: SymMash.new) }
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
end
