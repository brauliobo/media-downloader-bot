RSpec.describe TDBot::MessageLink do
  it 'links supergroup and channel messages by their server id' do
    expect(described_class.url(chat_id: -1_003_188_031_798, message_id: 42 << 20)).to eq('https://t.me/c/3188031798/42')
  end

  it 'has no link for private chats and basic groups' do
    expect(described_class.url(chat_id: 123, message_id: 42 << 20)).to be_nil
    expect(described_class.url(chat_id: -456, message_id: 42 << 20)).to be_nil
  end
end
