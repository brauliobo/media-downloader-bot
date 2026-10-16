require 'rails_helper'

RSpec.describe Bot::Worker::Client do
  def over_drb(client, remote) = client.instance_variable_set(:@transport, Bot::Worker::DRbTransport.new(nil, remote: remote))

  let(:client) { described_class.allocate }

  before { BotJob.dataset.delete }

  it 'uses the remote bot caption limit' do
    over_drb(client, double(max_caption: 4096))

    expect(client.max_caption).to eq(4096)
  end

  it 'answers the album results as messages' do
    over_drb(client, double(send_album: [{ id: 123 }]))

    expect(client.send_album(SymMash.new, 'text', uploads: []).map(&:id)).to eq([123])
  end

  it 'delegates job lifecycle calls over DRb' do
    remote = double
    over_drb(client, remote)
    allow(remote).to receive(:job_cancelled).with(id: 'job-id').and_return(true)
    allow(remote).to receive(:finish_job).with(id: 'job-id').and_return(true)

    expect(client.job_cancelled?('job-id')).to be(true)
    expect(client.finish_job('job-id')).to be(true)
  end

  it 'preserves a false cancellation response' do
    over_drb(client, double(job_cancelled: false))

    expect(client.job_cancelled?('job-id')).to be(false)
  end

  it 'uses the manager keyword interface over DRb' do
    manager = Manager.new
    job     = manager.jobs.submit(SymMash.new(from: { id: 123 }, chat: { id: 123 }, text: 'url'))
    over_drb(client, manager)

    expect(client.job_cancelled?(job[:id])).to be(false)
    expect(client.finish_job(job[:id])).to be(true)
  end

  describe 'while the bot is down' do
    let(:transport) do
      Class.new do
        attr_reader :calls

        def initialize(failures, error) = (@failures, @error, @calls = failures, error, 0)

        def call(method, result: nil, **)
          raise @error, 'down' if (@calls += 1) <= @failures

          { cancelled: true }[result]
        end
      end
    end

    def reaching(failures, error = Faraday::ConnectionFailed)
      transport.new(failures, error).tap do |remote|
        client.instance_variable_set(:@transport, remote)
        allow(client).to receive(:sleep)
        allow(client).to receive(:warn)
      end
    end

    it 'retries with a growing pause until it is back' do
      remote = reaching(3)

      expect(client.job_cancelled?('job-id')).to be(true)
      expect(remote.calls).to eq(4)
      expect(client).to have_received(:sleep).with(1.0).ordered
      expect(client).to have_received(:sleep).with(2.0).ordered
      expect(client).to have_received(:sleep).with(4.0).ordered
    end

    it 'waits for a DRb bot too, and never pauses longer than the cap' do
      reaching(8, DRb::DRbConnError)

      client.job_cancelled?('job-id')

      expect(client).to have_received(:sleep).with(described_class::PAUSE_MAX).at_least(:once)
    end

    it 'gives up after the retries' do
      stub_const("#{described_class}::RETRIES", 2)
      remote = reaching(10)

      expect { client.job_cancelled?('job-id') }.to raise_error(Faraday::ConnectionFailed)
      expect(remote.calls).to eq(3)
    end

    it 'does not retry what the bot answered with an error' do
      remote = reaching(1, RuntimeError)

      expect { client.job_cancelled?('job-id') }.to raise_error(RuntimeError)
      expect(remote.calls).to eq(1)
    end
  end

  it 'asks the bot which queue its jobs come from' do
    over_drb(client, double(queue_name: 'tdbot'))

    expect(client.queue_name).to eq('tdbot')
  end

  it 'refuses an address it has no transport for' do
    expect { described_class.new('ftp://host') }.to raise_error(ArgumentError, /Unsupported URI scheme/)
  end
end
