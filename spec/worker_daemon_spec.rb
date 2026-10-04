require 'rails_helper'

RSpec.describe Bot::JobRunner do
  describe '#monitor' do
    it 'terminates the job process group after cancellation is requested' do
      runner = described_class.new(cancelled: ->(_id) { true }, interrupted: ->(_id) {}, finished: ->(_id) {})
      allow(Process).to receive(:waitpid).and_return(nil, 123)
      allow(runner).to receive(:signal).and_return(true)
      allow(runner).to receive(:process_group_alive?).with(123).and_return(false)
      allow(runner).to receive(:sleep)

      runner.send(:monitor, 123, 'job-id')

      expect(runner).to have_received(:signal).with(123, :TERM)
    end

    it 'kills a process group that does not stop during the grace period' do
      runner = described_class.new(cancelled: ->(_id) { true }, interrupted: ->(_id) {}, finished: ->(_id) {})
      allow(Process).to receive(:waitpid).and_return(nil, 123)
      allow(runner).to receive(:signal).and_return(true)
      allow(runner).to receive(:process_group_alive?).with(123).and_return(true)
      allow(runner).to receive(:monotonic_time).and_return(0, described_class::CANCEL_GRACE_SECONDS)
      allow(runner).to receive(:sleep)

      runner.send(:monitor, 123, 'job-id')

      expect(runner).to have_received(:signal).with(123, :TERM).ordered
      expect(runner).to have_received(:signal).with(123, :KILL).ordered
    end

    it 'retries TERM when the process group is not ready yet' do
      runner = described_class.new(cancelled: ->(_id) { true }, interrupted: ->(_id) {}, finished: ->(_id) {})
      allow(Process).to receive(:waitpid).and_return(nil, nil, 123)
      allow(runner).to receive(:signal).with(123, :TERM).and_return(false, true)
      allow(runner).to receive(:process_group_alive?).with(123).and_return(false)
      allow(runner).to receive(:monotonic_time).and_return(0)
      allow(runner).to receive(:sleep)

      runner.send(:monitor, 123, 'job-id')

      expect(runner).to have_received(:signal).with(123, :TERM).twice
    end

    it 'interrupts the job process group with USR1 during a unit restart' do
      runner = described_class.new(cancelled: ->(_id) { false }, interrupted: ->(_id) { :restart }, finished: ->(_id) {})
      allow(Process).to receive(:waitpid).and_return(nil, 123)
      allow(runner).to receive(:signal).and_return(true)
      allow(runner).to receive(:process_group_alive?).with(123).and_return(false)
      allow(runner).to receive(:sleep)

      runner.send(:monitor, 123, 'job-id')

      expect(runner).to have_received(:signal).with(123, :USR1)
    end
  end

  describe '#run' do
    it 'cancels a threaded job when /stop marks it cancelled' do
      started   = Queue.new
      cancelled = false
      finished  = false
      runner    = described_class.new(
        cancelled:   ->(_id) { cancelled },
        interrupted: ->(_id) {},
        finished:    ->(_id) { finished = true },
      )

      thread = Thread.new do
        runner.run('job-id', fork: false) do
          started << true
          loop { sleep 0.05 }
        end
      end
      started.pop
      cancelled = true
      thread.join(2)

      expect(thread).not_to be_alive
      expect(finished).to eq(true)
    end
  end
end
