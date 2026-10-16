require 'rails_helper'
require_relative '../support/replaying_manager'

RSpec.describe Replay::GroupQueue do
  let(:dir)     { Dir.mktmpdir }
  let(:manager) { ReplayingManager.new }
  let(:engine)  { Tracked::Engine.new({ 'replay' => Replay::Handler.new(manager, forwarded: Forwarding::Log.new(path: File.join(dir, 'f.jsonl')), replayed: Replay::Log.new(path: File.join(dir, 'r.jsonl'))) }, tick: 0.01) }
  let(:service) { Class.new { include Manager::Service }.new.tap { |service| service.instance_variable_set(:@tracked, engine) } }
  let(:msg)     { SymMash.new(id: 99, chat: { id: -200 }) }

  after do
    Job.unfinished.select_map(:id).each { |id| engine.stop(id) }
    Timeout.timeout(5) { sleep 0.01 while Job.unfinished.any? }
    Job.dataset.delete
    FileUtils.remove_entry(dir)
  end

  def waiting_for(&condition) = Timeout.timeout(5) { sleep 0.01 until condition.call }

  it 'keeps a following job running for the messages posted later and processes them with its own slots' do
    job = service.group_queue(chat_id: -200, enabled: true, parallel: 2)
    waiting_for { Job[job[:id]].state == 'running' }

    expect(service.queue_message(msg)).to have_attributes(key: '-200:99', job_id: job[:id])
    waiting_for { JobItem.first(key: '-200:99').status == 'done' }

    expect(manager.replayed.map { |m| m[:id] }).to eq([99])
    expect(Job[job[:id]]).to have_attributes(state: 'running', parallel: 2)
  end

  it 'turns the queue off for the chat and back on in the same job' do
    job = service.group_queue(chat_id: -200, enabled: true)
    waiting_for { Job[job[:id]].state == 'running' }

    service.group_queue(chat_id: -200, enabled: false)
    expect(service.queue_message(msg)).to be_nil

    expect(service.group_queue(chat_id: -200, enabled: true, parallel: 3)).to include(id: job[:id], parallel: 3)
    expect(service.queue_message(msg)).to be_present
  end

  it 'keeps the messages in line while the queue is paused' do
    job = service.group_queue(chat_id: -200, enabled: true)
    waiting_for { Job[job[:id]].state == 'running' }
    engine.stop(job[:id])
    waiting_for { Job[job[:id]].state == 'stopped' }

    expect(service.queue_message(msg)).to have_attributes(status: 'pending')
    engine.resume(job[:id])
    waiting_for { JobItem.first(key: '-200:99').status == 'done' }
  end
end
