require 'rails_helper'

RSpec.describe Bot::Jobs, 'leases' do
  let(:jobs) { described_class.new(queue: 'lease') }
  let(:msg)  { SymMash.new(from: { id: 123 }, chat: { id: 123 }, message_id: 1, text: 'url') }

  def other(owner, id) = SymMash.new(from: { id: owner }, chat: { id: owner }, message_id: id, text: 'url')

  before { BotJob.dataset.delete }

  it 'hands a job to one worker at a time and leases it' do
    job = jobs.submit(msg)

    expect(jobs.dequeue(worker: 'w1')).to eq(job)
    expect(jobs.dequeue(worker: 'w2')).to be_nil
    expect(BotJob.with_pk!(job[:id])).to have_attributes(state: 'running', worker: 'w1', attempts: 1, lease_until: be > Time.now)
  end

  it "keeps a live worker's job as long as it heartbeats" do
    job = jobs.submit(msg)
    jobs.dequeue(worker: 'w1')
    BotJob.where(id: job[:id]).update(lease_until: Time.now - 1)
    jobs.heartbeat('w1')

    expect(jobs.dequeue(worker: 'w2')).to be_nil
  end

  it 'hands the job of a dead worker to the next one' do
    job = jobs.submit(msg)
    jobs.dequeue(worker: 'w1')
    BotJob.where(id: job[:id]).update(lease_until: Time.now - 1)

    expect(jobs.dequeue(worker: 'w2')).to eq(job)
    expect(BotJob.with_pk!(job[:id])).to have_attributes(worker: 'w2', attempts: 2)
  end

  it 'drops a job that keeps killing its workers' do
    job = jobs.submit(msg)
    BotJob.where(id: job[:id]).update(attempts: BotJob::MAX_ATTEMPTS, state: 'running', lease_until: Time.now - 1)

    expect(jobs.dequeue(worker: 'w2')).to be_nil
    expect(jobs.active?(job[:id])).to be(false)
  end

  it 'gives a released job back without counting the attempt' do
    job = jobs.submit(msg)
    jobs.dequeue(worker: 'w1')
    jobs.release(job[:id])

    expect(BotJob.with_pk!(job[:id])).to have_attributes(state: 'queued', worker: nil, attempts: 0)
    expect(jobs.dequeue(worker: 'w2')).to eq(job)
  end

  it 'serves the oldest first and holds a user at the limit back, except the admin' do
    first  = jobs.submit(other(1, 1))
    second = jobs.submit(other(1, 2))
    third  = jobs.submit(other(2, 3))

    expect(jobs.dequeue(worker: 'w1')).to eq(first)
    expect(jobs.dequeue(worker: 'w2')).to eq(third)
    expect(jobs.dequeue(worker: 'w3')).to be_nil
    jobs.finish(first[:id])
    expect(jobs.dequeue(worker: 'w3')).to eq(second)

    stub_const('Bot::MsgHelpers::ADMIN_CHAT_ID', 9)
    admin = [jobs.submit(other(9, 4)), jobs.submit(other(9, 5))]
    expect([jobs.dequeue(worker: 'w4'), jobs.dequeue(worker: 'w5')]).to eq(admin)
  end

  it 'forgets the jobs the bot ran itself when it restarts' do
    inline = jobs.register(msg)
    queued = jobs.submit(other(2, 2))
    jobs.drop_inline!

    expect(jobs.active?(inline[:id])).to be(false)
    expect(jobs.active?(queued[:id])).to be(true)
  end
end
