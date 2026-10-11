require 'rails_helper'

RSpec.describe ChatSetting do
  let(:chat_id) { -9_000_000_001 }

  around { |example| described_class.db.transaction(rollback: :always, auto_savepoint: true) { example.run } }

  it 'ignores a chat without a row' do
    expect(described_class.respond?(chat_id)).to be(false)
  end

  it 'enables and disables a chat, keeping its title' do
    described_class.set_respond(chat_id, true, title: 'Biblioteca')
    expect(described_class.respond?(chat_id)).to be(true)
    expect(described_class.responding).to include(chat_id)

    described_class.set_respond(chat_id, false)
    expect(described_class.respond?(chat_id)).to be(false)
    expect(described_class[chat_id].title).to eq('Biblioteca')
  end

  it 'gives the default option tokens of a chat, none without a row' do
    expect(described_class.default_options(chat_id)).to eq([])
    expect(described_class.default_options(nil)).to eq([])

    described_class.update_settings(chat_id, options: 'lang=pt hashtags')
    expect(described_class.default_options(chat_id)).to eq(%w[lang=pt hashtags])
  end

  it 'keeps the options when toggling respond and clears them with an empty string' do
    described_class.update_settings(chat_id, options: 'hashtags')
    described_class.set_respond(chat_id, true)
    expect(described_class[chat_id]).to have_attributes(respond: true, options: 'hashtags')

    described_class.update_settings(chat_id, options: '')
    expect(described_class.default_options(chat_id)).to eq([])
  end
end
