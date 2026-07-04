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

  describe '#message_result' do
    it 'serializes TD message objects without calling to_h' do
      message_class = Struct.new(:id, :media_group_id) do
        def to_h = raise('unexpected to_h')
      end
      message = message_class.new(123, 456)

      expect(described_class.allocate.message_result(message)).to eq(id: 123, media_group_id: 456)
    end
  end
end
