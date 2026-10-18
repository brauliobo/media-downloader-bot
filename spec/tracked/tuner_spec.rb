require 'rails_helper'

RSpec.describe Tracked::Tuner do
  let(:engine)  { Tracked::Engine.new({ 'fake' => Class.new(Tracked::Handler).new }) }
  let(:readings) { [] }
  let(:tuner)   { described_class.new(engine, backlog: -> { readings.shift }, max: 5, streak: 3, waiting: 2) }

  after { Job.dataset.delete }

  def job(parallel: 3, running: 3, pending: 2, **params)
    Job.create(kind: 'fake', state: 'running', parallel: parallel, params: params).tap do |job|
      { 'running' => running, 'pending' => pending }.each { |status, count| count.times { |n| JobItem.create(job_id: job.id, kind: 'fake', key: "#{job.id}-#{status}#{n}", status: status) } }
    end
  end

  def steps(*backlogs) = backlogs.each { |depth| readings << depth; tuner.step }

  it 'adds one when nothing has waited for a slot for a streak of readings, the job has all its items running and more waiting' do
    tuned = job(tune: true)

    steps(0, 0)
    expect(tuned.refresh.parallel).to eq(3)
    steps(0)
    expect(tuned.refresh.parallel).to eq(4)
  end

  it 'takes one off when several wait for a slot, and holds in between' do
    tuned = job(tune: true)

    steps(1, 1, 1, 2, 3, 2)
    expect(tuned.refresh.parallel).to eq(2)
  end

  it 'is not moved by a spike' do
    tuned = job(tune: true)

    steps(0, 0, 5, 0, 0, 5)
    expect(tuned.refresh.parallel).to eq(3)
  end

  it 'does not add what the job could not use: slots free, or nothing waiting' do
    idle   = job(tune: true, running: 2, pending: 2)
    done   = job(tune: true, running: 3, pending: 0)

    steps(0, 0, 0)
    expect([idle, done].map { |tuned| tuned.refresh.parallel }).to eq([3, 3])
  end

  it 'stays inside its limits' do
    top = job(tune: true, parallel: 5, running: 5)
    low = job(tune: true, parallel: 1, running: 1)

    steps(0, 0, 0)
    expect(top.refresh.parallel).to eq(5)
    steps(4, 4, 4)
    expect(low.refresh.parallel).to eq(1)
  end

  it 'leaves alone the jobs that did not ask for it, and reads nothing without one' do
    plain = job

    steps(0, 0, 0)
    expect(plain.refresh.parallel).to eq(3)
    expect(readings).to eq([0, 0, 0]) # nothing read them
  end
end
