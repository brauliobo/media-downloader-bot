require 'rails_helper'

RSpec.describe Bot::Worker::Client do
  def over_drb(client, remote) = client.instance_variable_set(:@transport, Bot::Worker::DRbTransport.new(nil, remote: remote))

  let(:client) { described_class.allocate }

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

  it 'refuses an address it has no transport for' do
    expect { described_class.new('ftp://host') }.to raise_error(ArgumentError, /Unsupported URI scheme/)
  end
end
