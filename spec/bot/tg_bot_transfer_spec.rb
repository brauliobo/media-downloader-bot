require 'rails_helper'

RSpec.describe Bot::TgBot do
  let(:bot)   { described_class.new }
  let(:tg)    { double('tg') }
  let(:dir)   { Dir.mktmpdir('tg-transfer-') }
  let(:agent) { instance_double(Mechanize, get: double(body: 'bytes')) }

  before do
    bot.tg = tg
    allow(bot).to receive(:throttle!)
    allow(Mechanize).to receive(:new).and_return(agent)
    allow(agent).to receive(:redirect_ok=)
  end

  after { FileUtils.remove_entry dir }

  describe '#download_file' do
    before { allow(tg).to receive(:get_file).and_return(double(file_path: 'documents/file_7.pdf')) }

    it 'downloads a bare file id under the name Telegram gave it' do
      path = bot.download_file('AgADfileid', dir: dir)

      expect(tg).to have_received(:get_file).with(file_id: 'AgADfileid')
      expect(path).to eq File.join(dir, 'file_7.pdf')
      expect(File.read(path)).to eq 'bytes'
    end

    it 'downloads a file described by a hash, keeping its file name' do
      path = bot.download_file({file_id: 'AgADfileid', file_name: 'book.pdf'}, dir: dir)

      expect(tg).to have_received(:get_file).with(file_id: 'AgADfileid')
      expect(path).to eq File.join(dir, 'book.pdf')
    end

    it 'downloads a file described by a message document' do
      path = bot.download_file(SymMash.new(file_id: 'AgADfileid', file_name: 'book.pdf'), dir: dir)

      expect(path).to eq File.join(dir, 'book.pdf')
    end

    it 'never follows a redirect to the file' do
      bot.download_file('AgADfileid', dir: dir)

      expect(agent).to have_received(:redirect_ok=).with(false)
    end

    it 'fails when Telegram returns no file path' do
      allow(tg).to receive(:get_file).and_return(double(file_path: nil))

      expect { bot.download_file('AgADfileid', dir: dir) }.to raise_error(RuntimeError, 'no file_path returned')
    end
  end

  describe '#send_album' do
    let(:msg)    { SymMash.new(chat: {id: 10}, message_id: 20) }
    let(:upload) { SymMash.new(fn_out: File.join(dir, '1.jpg'), mime: 'image/jpeg', type: SymMash.new(name: :document)).tap { File.write(_1.fn_out, '') } }

    it 'reports a Telegram failure with the response body' do
      response = double(body: '{"description":"too big"}')
      error    = Telegram::Bot::Exceptions::ResponseError.new(response: response)
      allow(tg).to receive(:send).and_raise(error)

      expect { bot.send_album(msg, 'caption', uploads: [upload]) }.to raise_error(RuntimeError, /ResponseError.*too big/m)
    end

    it 'reports any other failure by class and message' do
      allow(tg).to receive(:send).and_raise(IOError, 'closed stream')

      expect { bot.send_album(msg, 'caption', uploads: [upload]) }.to raise_error(RuntimeError, 'IOError: closed stream')
    end

    it 'answers the messages sent and replies to the incoming one' do
      sent = nil
      allow(tg).to receive(:send) { |_method, **payload| sent = payload; [double(to_h: {message_id: 99})] }

      result = bot.send_album(msg, 'caption', uploads: [upload])

      expect(result.map(&:message_id)).to eq [99]
      expect(sent).to include(chat_id: 10, reply_to_message_id: 20)
    end
  end

  describe 'deleting what was sent' do
    let(:msg) { SymMash.new(chat: {id: 10}, message_id: 20) }
    let(:api) { double('api', delete_message: true) }

    before do
      bot.tg = api
      allow(api).to receive(:send).and_return(double(to_h: {message_id: 99}))
    end

    it 'deletes the reply when asked' do
      bot.send_message(msg, 'oops', delete: 0)

      expect(api).to have_received(:delete_message).with(chat_id: 10, message_id: 99)
      expect(api).not_to have_received(:delete_message).with(chat_id: 10, message_id: 20)
    end

    it 'deletes the incoming message too when asked' do
      bot.send_message(msg, 'oops', delete_both: 0)

      expect(api).to have_received(:delete_message).with(chat_id: 10, message_id: 99)
      expect(api).to have_received(:delete_message).with(chat_id: 10, message_id: 20)
    end

    it 'replies to a message that only has an id' do
      bot.send_message(SymMash.new(chat: {id: 10}, id: 30), 'hi')

      expect(api).to have_received(:send).with('send_message', hash_including(reply_to_message_id: 30))
    end
  end
end
