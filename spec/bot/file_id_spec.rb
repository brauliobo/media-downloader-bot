require 'rails_helper'

RSpec.describe Bot::FileId do
  it 'keeps a numeric TDLib file id' do
    expect(described_class.call(42)).to eq(42)
    expect(described_class.call('42')).to eq(42)
  end

  it 'reads the inner file id from a TD document' do
    expect(described_class.call(double(document: double(id: 99)))).to eq(99)
  end

  it 'reads nested JSON hashes' do
    expect(described_class.call({ 'document' => { 'id' => 7 } })).to eq(7)
    expect(described_class.call(file_id: 8)).to eq(8)
  end

  it 'reads the inner file id of a TD video, audio or animation' do
    %w[video audio animation].each { |kind| expect(described_class.call(SymMash.new(kind => { id: 5 }))).to eq(5) }
  end

  it 'leaves a Bot API file id as it is' do
    expect(described_class.call('AgACAgIAAxkBAAI')).to eq('AgACAgIAAxkBAAI')
  end

  describe '.remote' do
    it 'reads the remote id of a TD document, as a hash or as a mash' do
      document = { 'document' => { 'id' => 7, 'remote' => { 'id' => 'BQACAgEA' } } }

      expect(described_class.remote(document)).to eq('BQACAgEA')
      expect(described_class.remote(SymMash.new(document))).to eq('BQACAgEA')
    end

    it 'reads the remote id of a TD video' do
      expect(described_class.remote(SymMash.new(video: { id: 7, remote: { id: 'BAACAgEA' } }))).to eq('BAACAgEA')
    end

    it 'has none for a bare id, a Bot API document or a file not uploaded yet' do
      expect(described_class.remote(42)).to be_nil
      expect(described_class.remote('AgACAgIAAxkBAAI')).to be_nil
      expect(described_class.remote({ document: { id: 7, remote: { id: '' } } })).to be_nil
      expect(described_class.remote({ file_id: 'AgACAgIAAxkBAAI' })).to be_nil
    end
  end

  describe '.fetchable' do
    let(:td)   { double('td') }
    let(:copy) { Tempfile.new('book') }

    before { allow(td).to receive(:get_remote_file).with(remote_file_id: 'remote', file_type: nil).and_return(double(value: double(id: 7, local: local))) }

    after { copy.close! }

    context 'when TDLib has the file as downloaded but its local copy is gone' do
      let(:local) { double(is_downloading_completed: true, path: '/tmp/gone/book.yml') }

      it 'forgets the copy, so the file is fetched from Telegram again' do
        expect(td).to receive(:delete_file).with(file_id: 7).and_return(double(value: true))

        expect(described_class.fetchable(td, 'remote')).to eq(7)
      end
    end

    context 'when the local copy is there' do
      let(:local) { double(is_downloading_completed: true, path: copy.path) }

      it 'leaves it alone' do
        expect(td).not_to receive(:delete_file)

        expect(described_class.fetchable(td, 'remote')).to eq(7)
      end
    end

    context 'when the file was not downloaded yet' do
      let(:local) { double(is_downloading_completed: false, path: '') }

      it 'leaves it alone' do
        expect(td).not_to receive(:delete_file)

        expect(described_class.fetchable(td, 'remote')).to eq(7)
      end
    end
  end

  describe '.name' do
    it 'reads the file name of a hash or of an object' do
      expect(described_class.name({ 'file_name' => 'a.pdf' })).to eq('a.pdf')
      expect(described_class.name(SymMash.new(file_name: 'b.pdf'))).to eq('b.pdf')
      expect(described_class.name(double(file_name: 'c.pdf'))).to eq('c.pdf')
    end

    it 'has none for a bare id or a blank name' do
      expect(described_class.name('AgACAgIAAxkBAAI')).to be_nil
      expect(described_class.name({ file_name: '' })).to be_nil
      expect(described_class.name(nil)).to be_nil
    end
  end
end
