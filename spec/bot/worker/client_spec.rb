require 'spec_helper'

RSpec.describe Bot::Worker::Client do
  describe '.td_file_id' do
    it 'keeps a numeric TDLib file id' do
      expect(described_class.td_file_id(42)).to eq(42)
      expect(described_class.td_file_id('42')).to eq(42)
    end

    it 'reads the inner file id from a TD document' do
      file = double(id: 99)
      doc  = double(document: file)
      expect(described_class.td_file_id(doc)).to eq(99)
    end

    it 'reads nested JSON hashes from the HTTP payload' do
      expect(described_class.td_file_id({'document' => {'id' => 7}})).to eq(7)
      expect(described_class.td_file_id(file_id: 8)).to eq(8)
    end
  end

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
    conn = Faraday.new(url: 'http://127.0.0.1:1181') do |f|
      f.request :json
      f.response :json
      f.adapter :test, stubs
    end
    client = described_class.new('http://127.0.0.1:1181')
    client.instance_variable_set(:@http_client, conn)

    path = client.download_file(double(document: double(id: 123)), dir: '/tmp')

    expect(path).to eq('/tmp/file.pdf')
    expect(payload['file_id_or_info']).to eq(123)
  ensure
    ENV['BOT_HTTP_TOKEN'] = token
  end
end
