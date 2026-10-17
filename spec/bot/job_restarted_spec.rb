require 'rails_helper'

# A job is stopped where its files are whole: it is asked to, and leaves at its next checkpoint.
RSpec.describe Bot::JobRestarted do
  after { described_class.reset! }

  it 'is taken at a checkpoint only once the stop was asked' do
    expect { described_class.check! }.not_to raise_error

    described_class.request!

    expect { described_class.check! }.to raise_error(described_class)
  end

  it 'is a checkpoint at every progress report of the job, from any of its threads' do
    updates = []
    status  = Bot::Status.new { |text| updates << text }
    status.add('step') { |line| line.update('step one') }
    described_class.request!

    expect { Thread.new { status.add('step two') { :never } }.tap { |t| t.report_on_exception = false }.join }.to raise_error(described_class)
    expect(updates).not_to include('step two')
  end

  describe 'in a pool' do
    it 'leaves the tasks not started and hands the stop to the caller once those under way ended' do
      ended = Queue.new
      pool  = JobPool.new(jobs: 1)

      expect do
        pool.each(%w[first second third], wait: true) do |name|
          ended << name
          described_class.request!
        end
      end.to raise_error(described_class)

      expect(ended.size).to eq(1)
    end

    it 'hands the stop to the consumer of an ordered map, instead of waiting for results that were left' do
      pool = JobPool.new(jobs: 2)
      described_class.request!

      expect { pool.ordered_map([1, 2, 3]) { |value| value }.to_a }.to raise_error(described_class)
    end

    it 'waits for the batches under way of a pipeline before the stop leaves' do
      finished = Queue.new
      expect do
        Pipeline.each(%w[a b c d], tasks: 1, batch: 2, perform: ->(item) { item }) do |group|
          described_class.request!
          sleep 0.1
          finished << group
        end
      end.to raise_error(described_class)

      expect(finished.size).to be >= 1
    end
  end
end
