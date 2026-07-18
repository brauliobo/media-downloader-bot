require 'uri'
require_relative '../../lib/td_bot/chat_identifier'

RSpec.describe TDBot::ChatIdentifier do
  describe '.resolve' do
    it 'uses the TD client public chat resolver for usernames' do
      td = instance_double('TD::Client')
      allow(td).to receive(:resolve_public_chat).with('materials_channel').and_return(:chat)

      expect(described_class.resolve(td, '@materials_channel')).to eq(:chat)
    end

    it 'loads numeric chat IDs directly' do
      td     = instance_double('TD::Client')
      result = instance_double('Concurrent::Promises::Future')
      allow(td).to receive(:get_chat).with(chat_id: -1003188031798).and_return(result)
      allow(result).to receive(:value).with(15).and_return(:chat)

      expect(described_class.resolve(td, '-1003188031798')).to eq(:chat)
    end
  end

  describe '.public_username' do
    it 'normalizes usernames and Telegram links' do
      expect(described_class.public_username('@materiais_vale_do_amanhecer')).to eq('materiais_vale_do_amanhecer')
      expect(described_class.public_username('https://t.me/materiais_vale_do_amanhecer')).to eq('materiais_vale_do_amanhecer')
      expect(described_class.public_username('tg://resolve?domain=materiais_vale_do_amanhecer')).to eq('materiais_vale_do_amanhecer')
    end

    it 'rejects numeric and unsupported identifiers' do
      expect(described_class.public_username('-1003188031798')).to be_nil
      expect(described_class.public_username('https://t.me/c/123/456')).to be_nil
    end
  end

  describe '.numeric_id' do
    it 'accepts signed Telegram chat IDs' do
      expect(described_class.numeric_id('-1003188031798')).to eq(-1003188031798)
    end
  end
end
