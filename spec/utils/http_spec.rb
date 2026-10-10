require 'rails_helper'

RSpec.describe Utils::HTTP do
  after { described_class.reset! }

  describe '.client' do
    it 'does not keep HTTP connections alive' do
      agent = described_class.client

      expect(agent.keep_alive).to be(false)
      expect(agent.idle_timeout).to eq(0)
    end
  end

  describe '.download_public' do
    it 'rejects private addresses before opening a destination file' do
      Dir.mktmpdir('http-download-') do |dir|
        path = File.join(dir, 'payload.bin')

        expect {
          described_class.download_public('http://127.0.0.1/secret', path)
        }.to raise_error(ArgumentError, /public addresses/)
        expect(File.exist?(path)).to eq(false)
        expect(File.exist?("#{path}.part")).to eq(false)
      end
    end
  end

  describe '.get_public' do
    it 'prefers IPv4 and falls back when that address times out' do
      allow(Utils::Safety).to receive(:public_addresses).with('example.com').and_return(['2001:db8::1', '203.0.113.10'])
      calls = []
      allow(Net::HTTP).to receive(:new) do |_host, _port|
        http = instance_double(Net::HTTP)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:ipaddr=) { |ip| calls << ip }
        allow(http).to receive(:request) do |_req, &block|
          raise Net::OpenTimeout, 'expired' if calls.last == '203.0.113.10'

          res = instance_double(Net::HTTPResponse)
          allow(res).to receive(:is_a?) { |klass| klass == Net::HTTPSuccess }
          allow(res).to receive(:[]).with('content-length').and_return(nil)
          allow(res).to receive(:[]).with('content-type').and_return('text/plain')
          allow(res).to receive(:read_body).and_yield('body')
          block.call(res)
        end
        http
      end

      expect(described_class.get_public('https://example.com/post')).to eq('body')
      expect(calls).to eq(['203.0.113.10', '2001:db8::1'])
    end
  end

  describe '.reset!' do
    it 'drops the thread-local agent' do
      first = described_class.client
      described_class.reset!

      expect(described_class.client).not_to equal(first)
    end
  end

  describe '.post' do
    it 'retries through the shared HTTP helper' do
      calls = 0
      agent = stub_http_client
      allow(Kernel).to receive(:sleep)
      allow(agent).to receive(:post) do
        calls += 1
        raise EOFError if calls == 1

        :ok
      end

      expect(described_class.post('http://example.test', '{}')).to eq(:ok)
      expect(calls).to eq(2)
    end
  end

  describe '.url' do
    it 'joins a service base and an endpoint however the base ends' do
      expect(described_class.url('http://host:9000/', '/v1/vad')).to eq('http://host:9000/v1/vad')
      expect(described_class.url(URI.parse('http://host:9000'), '/v1/vad')).to eq('http://host:9000/v1/vad')
    end
  end
end
