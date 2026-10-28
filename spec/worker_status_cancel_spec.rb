require 'rails_helper'

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

      def report_error(_msg, _e, **_params); end
    end.new
  end

  it 'keeps the cancel control through updates and removes it from retained statuses' do
    worker = described_class.new(msg, service: service, job_id: 'job-id', skip_cleanup: true)
    worker.send(:init_status)
    worker.st.add('working') { |line| line.error('failed') }
    worker.send(:clear_cancel_button)

    expect(service.sent.last).to include(cancel_job: 'job-id')
    expect(service.edited[-2].last).to include(cancel_job: 'job-id')
    expect(service.edited[-2].last).to include(force: false)
    expect(service.edited.last.last).to include(cancel_job: false)
    expect(service.edited.last.last).to include(force: true)
  end

  it 'replaces a queued status with the initial active status' do
    msg.resp = SymMash.new(message_id: 789)
    worker = described_class.new(msg, service: service, job_id: 'job-id', skip_cleanup: true)

    worker.send(:init_status)

    expect(service.sent).to be_nil
    expect(service.edited.last).to eq([789, {text: 'Downloading metadata\\.\\.\\.', cancel_job: 'job-id', force: true}])
  end

  describe 'a job taken again' do
    before do
      BotJob.dataset.delete
      BotJob.dataset.insert(id: 'job-id', queue: 'tdbot', key: '123:1', attempts: 2, message: Sequel.pg_jsonb(text: 'url'))
      msg.resp = SymMash.new(message_id: 111)
    end

    after { BotJob.dataset.delete }

    it 'edits the status of the earlier attempt while its files are there' do
      worker = described_class.new(msg, service: service, job_id: 'job-id', skip_cleanup: true)
      worker.instance_variable_set(:@kept_files, true)

      worker.send(:init_status)

      expect(service.deleted).to be_empty
      expect(service.edited.last.first).to eq(111)
    end

    it 'starts over with a new status when the files are gone, the old one would show the progress of a run that is gone' do
      worker = described_class.new(msg, service: service, job_id: 'job-id', skip_cleanup: true)
      worker.instance_variable_set(:@kept_files, false)

      worker.send(:init_status)

      expect(service.deleted.map(&:first)).to eq([111])
      expect(service.edited).to be_empty
      expect(msg.resp.message_id).to eq(789)
    end
  end

  it 'posts a status once and keeps its id in the job, for a worker resuming it to edit' do
    BotJob.dataset.delete
    BotJob.dataset.insert(id: 'job-id', queue: 'tdbot', key: '123:1', message: Sequel.pg_jsonb(text: 'url'))
    worker = described_class.new(msg, service: service, job_id: 'job-id', skip_cleanup: true)

    worker.send(:init_status)

    expect(BotJob.first(id: 'job-id').message.to_h).to eq('text' => 'url', 'resp' => { 'message_id' => 789 })
  ensure
    BotJob.dataset.delete
  end

  it 'posts a new status when the one a dead run left cannot be edited' do
    msg.resp = SymMash.new(message_id: 111)
    allow(service).to receive(:edit_message).and_return(false)
    worker = described_class.new(msg, service: service, job_id: nil, skip_cleanup: true)

    worker.send(:init_status)

    expect(service.sent.first).to eq('Downloading metadata\\.\\.\\.')
    expect(msg.resp.message_id).to eq(789)
  end

  it 'replaces the status with Cancelled when execution is interrupted' do
    worker = described_class.new(msg, service: service, job_id: 'job-id', skip_cleanup: true)
    worker.send(:init_status)
    allow(worker).to receive(:run).and_raise(Bot::JobCancelled)

    expect { worker.process }.to raise_error(Bot::JobCancelled)
    expect(service.edited.last.last).to include(text: 'Cancelled', cancel_job: false, force: true)
  end

  it 'replaces the status with a restart notice when the unit stops' do
    worker = described_class.new(msg, service: service, job_id: 'job-id', skip_cleanup: true)
    worker.send(:init_status)
    allow(worker).to receive(:run).and_raise(Bot::JobRestarted)

    expect { worker.process }.to raise_error(Bot::JobRestarted)
    expect(service.edited.last.last).to include(text: 'Restarting\\.\\.\\.', cancel_job: false, force: true)
  end

  it 'replaces the initial metadata status when processing raises' do
    worker = described_class.new(msg, service: service, job_id: 'job-id', skip_cleanup: true)
    worker.send(:init_status)
    allow(worker).to receive(:run).and_raise(ArgumentError, 'URL must resolve only to public addresses')

    expect { worker.process }.not_to raise_error
    expect(service.edited.last.last[:text]).to include('Processing error')
    expect(service.edited.last.last[:text]).to include('ArgumentError')
    expect(service.edited.last.last).to include(cancel_job: false, force: true)
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
