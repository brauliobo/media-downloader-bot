require 'spec_helper'

RSpec.describe Worker, 'job status controls' do
  let(:msg) { SymMash.new(from: {id: 123}, chat: {id: 123}, text: 'https://example.com') }
  let(:service) do
    Class.new do
      attr_reader :sent, :edited, :deleted

      def initialize
        @edited  = []
        @deleted = []
      end

      def send_message(_msg, text, **params)
        @sent = [text, params]
        SymMash.new(message_id: 789)
      end

      def edit_message(_msg, id, **params)
        @edited << [id, params]
        true
      end

      def delete_message(_msg, id, **params)
        @deleted << [id, params]
      end
    end.new
  end

  it 'keeps the cancel control through updates and removes it from retained statuses' do
    worker = described_class.new(msg, service: service, job_id: 'job-id', skip_cleanup: true)
    worker.send(:init_status)
    worker.st.add('working') { |line| line.error('failed') }
    worker.send(:clear_cancel_button)

    expect(service.sent.last).to include(cancel_job: 'job-id')
    expect(service.edited[-2].last).to include(cancel_job: 'job-id')
    expect(service.edited.last.last).to include(cancel_job: false)
  end

  it 'replaces the status with Cancelled when execution is interrupted' do
    worker = described_class.new(msg, service: service, job_id: 'job-id', skip_cleanup: true)
    worker.send(:init_status)
    allow(worker).to receive(:run).and_raise(Bot::JobCancelled)

    expect { worker.process }.to raise_error(Bot::JobCancelled)
    expect(service.edited.last.last).to include(text: 'Cancelled', cancel_job: false)
  end

  it 'removes the work directory synchronously when cancelled' do
    Dir.mktmpdir do |tmpdir|
      worker   = described_class.new(msg, service: service, tmpdir: tmpdir, workdir_path: nil)
      work_dir = nil
      allow(worker).to receive(:cleanup_workdir)

      expect do
        worker.workdir do |dir|
          work_dir = dir
          File.write(File.join(dir, 'partial'), 'data')
          raise Bot::JobCancelled
        end
      end.to raise_error(Bot::JobCancelled)

      expect(Dir.exist?(work_dir)).to be(false)
      expect(worker).not_to have_received(:cleanup_workdir)
    end
  end
end
