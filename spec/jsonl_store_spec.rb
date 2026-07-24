require 'spec_helper'
require_relative '../lib/jsonl_store'

RSpec.describe JsonlStore do
  let(:dir) { Dir.mktmpdir('jsonl-store-') }
  let(:path) { File.join(dir, 'records.jsonl') }
  let(:store) { described_class.new(path) }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  it 'appends durable records and reads them with symbolized keys' do
    store.append(kind: 'discourse', slug: 'first')
    store.append(kind: 'book', slug: 'second')

    expect(store.to_a).to eq([
      {kind: 'discourse', slug: 'first'},
      {kind: 'book', slug: 'second'}
    ])
  end

  it 'returns no records when the store does not exist' do
    expect(store.to_a).to eq([])
  end
end
