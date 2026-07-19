require 'spec_helper'
require_relative '../lib/worker_daemon'

RSpec.describe WorkerDaemon do
  describe '#monitor_job' do
    it 'terminates the job process group after cancellation is requested' do
      daemon = described_class.new('druby://127.0.0.1:1188')
      service = double
      allow(Process).to receive(:waitpid).and_return(nil, 123)
      allow(daemon).to receive(:job_cancelled?).with(service, 'job-id').and_return(true)
      allow(daemon).to receive(:signal_job).and_return(true)
      allow(daemon).to receive(:process_group_alive?).with(123).and_return(false)
      allow(daemon).to receive(:sleep)

      daemon.send(:monitor_job, 123, 'job-id', service)

      expect(daemon).to have_received(:signal_job).with(123, :TERM)
    end

    it 'kills a process group that does not stop during the grace period' do
      daemon  = described_class.new('druby://127.0.0.1:1188')
      service = double
      allow(Process).to receive(:waitpid).and_return(nil, 123)
      allow(daemon).to receive(:job_cancelled?).with(service, 'job-id').and_return(true)
      allow(daemon).to receive(:signal_job).and_return(true)
      allow(daemon).to receive(:process_group_alive?).with(123).and_return(true)
      allow(daemon).to receive(:monotonic_time).and_return(0, described_class::CANCEL_GRACE_SECONDS)
      allow(daemon).to receive(:sleep)

      daemon.send(:monitor_job, 123, 'job-id', service)

      expect(daemon).to have_received(:signal_job).with(123, :TERM).ordered
      expect(daemon).to have_received(:signal_job).with(123, :KILL).ordered
    end

    it 'retries TERM when the process group is not ready yet' do
      daemon  = described_class.new('druby://127.0.0.1:1188')
      service = double
      allow(Process).to receive(:waitpid).and_return(nil, nil, 123)
      allow(daemon).to receive(:job_cancelled?).with(service, 'job-id').and_return(true)
      allow(daemon).to receive(:signal_job).with(123, :TERM).and_return(false, true)
      allow(daemon).to receive(:process_group_alive?).with(123).and_return(false)
      allow(daemon).to receive(:monotonic_time).and_return(0)
      allow(daemon).to receive(:sleep)

      daemon.send(:monitor_job, 123, 'job-id', service)

      expect(daemon).to have_received(:signal_job).with(123, :TERM).twice
    end
  end
end
