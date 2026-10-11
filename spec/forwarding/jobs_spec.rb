require 'rails_helper'
require 'tmpdir'
require_relative '../support/forwarding_bot'

RSpec.describe Forwarding::Jobs do
  let(:dir) { Dir.mktmpdir }
  let(:log) { Forwarding::Log.new(path: File.join(dir, 'forwarded.jsonl')) }

  after { FileUtils.remove_entry(dir) }

  def finished(jobs, job) = Timeout.timeout(2) { sleep 0.01 until %w[completed failed].include?(jobs.fetch(job[:id])[:state]) }.then { jobs.fetch(job[:id]) }

  it 'runs a forwarding and exposes its progress' do
    bot  = ForwardingBot.new(message_ids: [1, 2, 3])
    jobs = described_class.new(-> { bot }, log: log)
    job  = jobs.start(source: { chat_id: '-100', topic_id: '0' }, target: { chat_id: -200 }, caption: 'lang=pt', leave: '1')

    expect(job).to include(state: 'queued', source: { chat_id: -100, topic_id: nil }, caption: 'lang=pt', leave: true)
    expect(finished(jobs, job)).to include(state: 'completed', total: 3, sent: 3, left: true)
    expect(bot.left).to eq([-100])
    expect(jobs.list.map { |j| j[:id] }).to eq([job[:id]])
  end

  it 'fails the job when the bot cannot do the operation' do
    jobs = described_class.new(-> { Bot::Base.new }, log: log)
    job  = jobs.start(source: { chat_id: -100 }, target: { chat_id: -200 })

    expect(finished(jobs, job)[:errors].first[:error]).to include('NotImplementedError')
  end
end
