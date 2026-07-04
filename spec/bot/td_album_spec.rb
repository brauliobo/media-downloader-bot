require 'spec_helper'

begin
  require_relative '../../lib/bot/td_bot'
  td_load_error = nil
rescue LoadError => e
  td_load_error = e
end

if td_load_error
  RSpec.describe 'Bot::TDBot album support' do
    it 'requires tdlib-ruby' do
      skip td_load_error.message
    end
  end
else

  RSpec.describe Bot::TDBot do
    let(:dir) { Dir.mktmpdir('td-album-') }
    let(:bot) { described_class.new }

    after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

    it 'delegates album sending to tdlib-ruby message sender' do
      path = File.join(dir, 'photo.jpg')
      File.write(path, '')

      msg            = SymMash.new(chat: {id: 123})
      upload         = SymMash.new(fn_out: path, mime: 'image/jpeg')
      message        = double(id: 456)
      message_sender = double(send_media_album: [message])
      allow(bot).to receive(:message_sender).and_return(message_sender)
      allow(bot).to receive(:finalize_sent_message)

      expect(bot.send_album(msg, 'caption', uploads: [upload])).to eq([message])
      expect(message_sender).to have_received(:send_media_album).with(
        123, [upload], caption: 'caption', parse_mode: 'MarkdownV2', timeout: 1_800
      )
    end

    it 'sends full long album captions as text and keeps a truncated media caption' do
      text = 'a' * (described_class::MEDIA_CAPTION_LIMIT + 1)
      msg  = SymMash.new(chat: {id: 123})
      allow(bot).to receive(:send_message)

      expect(bot.album_caption_text(msg, text, 'MarkdownV2')).to eq(text.first(described_class::MEDIA_CAPTION_LIMIT))
      expect(bot).to have_received(:send_message).with(msg, text, parse_mode: 'MarkdownV2')
    end

    it 'delegates long album sending with a truncated media caption' do
      path = File.join(dir, 'photo.jpg')
      File.write(path, '')

      msg            = SymMash.new(chat: {id: 123})
      text           = 'a' * (described_class::MEDIA_CAPTION_LIMIT + 1)
      upload         = SymMash.new(fn_out: path, mime: 'image/jpeg')
      message        = double(id: 456)
      message_sender = double(send_media_album: [message])
      allow(bot).to receive(:message_sender).and_return(message_sender)
      allow(bot).to receive(:send_message)
      allow(bot).to receive(:finalize_sent_message)

      bot.send_album(msg, text, uploads: [upload])

      expect(bot).to have_received(:send_message).with(msg, text, parse_mode: 'MarkdownV2')
      expect(message_sender).to have_received(:send_media_album).with(
        123, [upload], caption: text.first(described_class::MEDIA_CAPTION_LIMIT), parse_mode: 'MarkdownV2', timeout: 1_800
      )
    end

    it 'wraps TD message objects without passing them to SymMash' do
      message_class = Struct.new(:id) do
        def each_pair = raise('unexpected each_pair')
      end

      expect(bot.send(:td_message_response, message_class.new(123))).to eq(message_id: 123, id: 123)
    end
  end
end
