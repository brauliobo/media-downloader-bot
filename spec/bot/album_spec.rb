require 'spec_helper'

RSpec.describe Bot::Album do
  it 'keeps captions on the first item of each transport batch' do
    uploads = (1..11).map { |id| SymMash.new(id: id) }
    album   = described_class.new(uploads, 'caption')

    expect(album.batches.map { |batch| batch.uploads.size }).to eq([10, 1])
    expect(album.batches.map(&:caption)).to eq(['caption', nil])
    expect(album.items.map(&:last)).to eq(['caption'] + Array.new(9, '') + [''])
  end
end
