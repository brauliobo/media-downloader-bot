require 'rails_helper'
require 'drb/drb'

RSpec.describe Bot::Worker::Client do
  it 'posts a numeric file id to download_file' do
    token = ENV['BOT_HTTP_TOKEN']
    ENV['BOT_HTTP_TOKEN'] = 'token'
    payload = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post('/download_file') do |env|
        payload = JSON.parse(env.body)
        [200, {'Content-Type' => 'application/json'}, {'path' => '/tmp/file.pdf'}]
      end
    end
    client = described_class.new('http://127.0.0.1:1181')
    client.instance_variable_get(:@transport).instance_variable_get(:@client).instance_variable_get(:@conn).adapter :test, stubs

    path = client.download_file(double(document: double(id: 123)), dir: '/tmp')

    expect(path).to eq('/tmp/file.pdf')
    expect(payload['file_id_or_info']).to eq(123)
  ensure
    ENV['BOT_HTTP_TOKEN'] = token
  end

  it 'sends the remote id of a document with its file id, which TDLib renumbers when the bot restarts' do
    token = ENV['BOT_HTTP_TOKEN']
    ENV['BOT_HTTP_TOKEN'] = 'token'
    payload = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post('/download_file') do |env|
        payload = JSON.parse(env.body)
        [200, {'Content-Type' => 'application/json'}, {'path' => '/tmp/file.pdf'}]
      end
    end
    client = described_class.new('http://127.0.0.1:1181')
    client.instance_variable_get(:@transport).instance_variable_get(:@client).instance_variable_get(:@conn).adapter :test, stubs

    client.download_file(SymMash.new(document: { id: 123, remote: { id: 'BQACAgEA' } }), dir: '/tmp')

    expect(payload).to include('file_id_or_info' => 123, 'remote_id' => 'BQACAgEA')
  ensure
    ENV['BOT_HTTP_TOKEN'] = token
  end

  it 'round-trips send_message and download_file over DRb' do
    manager = Manager.new
    bot     = double
    seen    = nil
    msg     = SymMash.new(chat: {id: 1}, from: {id: 2})
    doc     = Struct.new(:document).new(Struct.new(:id).new(5))
    manager.instance_variable_set(:@bot, bot)
    allow(bot).to receive(:send_message).and_return(SymMash.new(message_id: 99, text: 'hi'))
    allow(bot).to receive(:download_file) do |info, **|
      seen = info
      '/tmp/out.pdf'
    end

    DRb.start_service('druby://127.0.0.1:0', manager)
    client = described_class.new(DRb.uri)
    sent   = client.send_message(msg, 'hi')
    path   = client.download_file(doc, dir: '/tmp')

    expect(sent.message_id).to eq(99)
    expect(path).to eq('/tmp/out.pdf')
    expect(seen.document.id).to eq(5)
  ensure
    DRb.stop_service
  end
end
