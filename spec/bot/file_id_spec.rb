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
end
