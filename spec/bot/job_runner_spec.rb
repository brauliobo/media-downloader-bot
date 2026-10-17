require 'rails_helper'

RSpec.describe Bot::JobRunner do
  let(:finished) { [] }
  let(:asked)    { [true] }

  def runner = described_class.new(cancelled: ->(_) { false }, interrupted: ->(_) { :restart if asked.first }, finished: ->(id) { finished << id })

  before { stub_const("#{described_class}::CANCEL_POLL_INTERVAL", 0.02) }

  after { Bot::JobRestarted.reset! }

  it 'asks the job to stop and waits for its checkpoint, without throwing the stop into it' do
    stub_const("#{described_class}::STOP_GRACE", 30)
    thrown = :no

    runner.run(1) do
      loop { Bot::JobRestarted.check!; sleep 0.01 }
    rescue Bot::JobRestarted
      thrown = :at_checkpoint
      raise
    end

    expect(thrown).to eq(:at_checkpoint)
    expect(finished).to eq([1])
  end

  it 'throws the stop into a job that reaches no checkpoint in the grace time' do
    stub_const("#{described_class}::STOP_GRACE", 0.1)
    stopped = false

    runner.run(2) do
      sleep
    rescue Bot::JobRestarted
      stopped = true
      raise
    end

    expect(stopped).to be(true)
    expect(finished).to eq([2])
  end
end
