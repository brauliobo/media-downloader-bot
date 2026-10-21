require 'rails_helper'

RSpec.describe Worker::Scaler do
  FakeSystemd = Struct.new(:running, :started) do
    def active(_unit) = running
    def start(_unit, instances) = started.concat(instances)
  end

  let(:jobs)    { Bot::Jobs.new(queue: 'scaler-spec') }
  let(:systemd) { FakeSystemd.new([1, 2], []) }
  let(:scaler)  { described_class.new(queue: 'scaler-spec', max: 8, systemd: systemd) }

  before { BotJob.dataset.delete }
  after  { BotJob.dataset.delete }

  def waiting(user, id) = jobs.submit(SymMash.new(from: { id: user }, chat: { id: user }, message_id: id, text: 'book'))

  def running(user, id)
    BotJob.dataset.insert(id: "run-#{id}", queue: 'scaler-spec', key: "#{user}:#{id}", owner_id: user, chat_id: user,
                          message: Sequel.pg_jsonb({}), state: 'running', worker: "w#{id}", lease_until: Time.now + 60)
  end

  it 'starts the lowest instances not running, one per job in progress or waiting' do
    running(10, 1)
    running(11, 2)
    [12, 13, 14].each { |user| waiting(user, user) }

    scaler.step

    expect(systemd.started).to eq([3, 4, 5])
  end

  it 'asks for no worker for a user at the limit: the claim would not give them one' do
    running(10, 1)
    waiting(10, 2)
    waiting(10, 3)

    scaler.step

    expect(systemd.started).to be_empty
  end

  it 'never goes past the maximum, nor starts more than a few at a time' do
    10.times { |n| waiting(100 + n, n) }

    scaler.step
    expect(systemd.started).to eq([3, 4, 5, 6])

    systemd.running = (1..8).to_a
    systemd.started.clear
    scaler.step
    expect(systemd.started).to be_empty
  end

  it 'starts nothing when nothing waits' do
    systemd.running = []
    scaler.step

    expect(systemd.started).to be_empty
  end
end
