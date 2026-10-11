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

  it 'leaves a Bot API file id as it is' do
    expect(described_class.call('AgACAgIAAxkBAAI')).to eq('AgACAgIAAxkBAAI')
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
