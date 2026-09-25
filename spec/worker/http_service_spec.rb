require 'spec_helper'

RSpec.describe Bot::Worker::HTTPService do
  describe '.bind_host' do
    around do |example|
      original = ENV['BOT_HTTP_BIND']
      ENV.delete('BOT_HTTP_BIND')
      example.run
    ensure
      ENV['BOT_HTTP_BIND'] = original
    end

    it 'normalizes localhost to the IPv4 loopback for Puma binding' do
      expect(described_class.bind_host('localhost')).to eq('127.0.0.1')
      expect(described_class.bind_host('LOCALHOST')).to eq('127.0.0.1')
    end

    it 'uses the default bind host for blank input' do
      expect(described_class.bind_host('')).to eq('127.0.0.1')
      expect(described_class.bind_host(nil)).to eq('127.0.0.1')
    end

    it 'keeps explicit bind addresses' do
      expect(described_class.bind_host('0.0.0.0')).to eq('0.0.0.0')
    end
  end

  describe '#allowed_roots' do
    around do |example|
      original = ENV['BOT_ALLOWED_PATH_ROOTS']
      ENV.delete('BOT_ALLOWED_PATH_ROOTS')
      example.run
    ensure
      ENV['BOT_ALLOWED_PATH_ROOTS'] = original
    end

    it 'allows app tmp paths for worker-proxied uploads' do
      roots = described_class.allocate.allowed_roots

      expect(roots).to include(File.expand_path(File.join(Dir.pwd, 'tmp')))
    end
  end

  describe 'errors' do
    around do |example|
      original = ENV['BOT_HTTP_TOKEN']
      ENV['BOT_HTTP_TOKEN'] = 'token'
      example.run
    ensure
      ENV['BOT_HTTP_TOKEN'] = original
    end

    it 'answers the exception for the client to raise' do
      service = Object.new
      def service.max_caption = raise(ArgumentError, 'Request Entity Too Large')
      port   = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
      thread = described_class.start(service, port)
      client = Bot::Worker::HTTPClient.new("http://127.0.0.1:#{port}")

      expect { expect { client.post(:max_caption) }.to output(/max_caption/).to_stderr }
        .to raise_error(Bot::Worker::HTTPClient::Error, 'bot HTTP service /max_caption returned 500: ArgumentError: Request Entity Too Large')
    ensure
      thread&.kill
    end
  end
end
