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
end
