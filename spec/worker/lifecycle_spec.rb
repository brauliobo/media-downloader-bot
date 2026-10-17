require 'rails_helper'

RSpec.describe Worker, 'lifecycle' do
  let(:msg)  { SymMash.new(from: {id: 123}, chat: {id: 123}, text: 'hello') }
  let(:dir)  { Dir.mktmpdir('worker-lifecycle-') }
  let(:service_class) do
    Class.new do
      attr_reader :sent, :edited, :deleted, :errors
      attr_accessor :failing_edits

      def initialize
        @edited  = []
        @deleted = []
        @errors  = []
        @failing_edits = 0
      end

      def send_message(_msg, text, **params)
        @sent = [text, params]
        SymMash.new(message_id: 789)
      end

      def edit_message(_msg, id, **params)
        raise 'cannot parse entities' if (@failing_edits -= 1) >= 0

        @edited << [id, params]
        true
      end

      def delete_message(_msg, id, **params) = @deleted << [id, params]
      def report_error(_msg, error, **_params) = @errors << error
    end
  end
  let(:service) { service_class.new }
  let(:worker)  { described_class.new(msg, service: service, job_id: 'job-id', tmpdir: dir, workdir_path: nil, skip_cleanup: nil) }

  after { FileUtils.remove_entry dir }

  describe 'the working directory' do
    before { allow(Process).to receive(:spawn).and_return(1) }

    before { allow(Process).to receive(:detach) }

    it 'is made under the temporary root and removed later, detached from this process' do
      path = nil
      worker.workdir { |work_dir| path = work_dir }

      expect(path).to start_with dir
      expect(Process).to have_received(:spawn).with('sh', '-c', "sleep 30 && rm -rf #{path.shellescape}", out: File::NULL, err: File::NULL)
      expect(Process).to have_received(:detach).with(1)
    end

    it 'is named after the job, so the job finds its files again when it is taken after a stop' do
      path = nil
      expect { worker.workdir { |work_dir| File.write(File.join(path = work_dir, 'page-1.wav'), 'audio'); raise Bot::JobRestarted } }.to raise_error(Bot::JobRestarted)

      expect(path).to eq File.join(dir, 'job-job-id')
      expect(Process).not_to have_received(:spawn)
      described_class.new(msg, service: service, job_id: 'job-id', tmpdir: dir, workdir_path: nil, skip_cleanup: nil).workdir do |work_dir|
        expect(File.read(File.join(work_dir, 'page-1.wav'))).to eq 'audio'
      end
    end

    it 'gives the inputs of a job a directory of a fixed name, unless the work dir was chosen' do
      worker.workdir do |work_dir|
        expect(worker.send(:input_dir, work_dir)).to eq File.join(work_dir, 'input')
      end
      chosen = described_class.new(msg, service: service, job_id: 'job-id', tmpdir: dir, workdir_path: File.join(dir, 'out'), skip_cleanup: true)
      chosen.workdir { |work_dir| expect(chosen.send(:input_dir, work_dir)).not_to eq File.join(work_dir, 'input') }
    end

    it 'is pruned, once nobody has taken the job for long' do
      old, recent = %w[job-old job-recent].map { |name| FileUtils.mkdir_p(File.join(dir, name)).first }
      File.utime(Time.now - 3.days, Time.now - 3.days, old)

      described_class.prune_workdirs(older_than: 2.days, root: dir)

      expect([File.exist?(old), File.exist?(recent)]).to eq [false, true]
    end

    it 'is removed right away when the job is cancelled' do
      path = nil

      expect { worker.workdir { |work_dir| path = work_dir; raise Bot::JobCancelled } }.to raise_error(Bot::JobCancelled)
      expect(File.exist?(path)).to be false
      expect(Process).not_to have_received(:spawn)
    end

    it 'is kept when cleanup is skipped' do
      worker = described_class.new(msg, service: service, tmpdir: dir, workdir_path: nil, skip_cleanup: true)
      path   = nil
      worker.workdir { |work_dir| path = work_dir }

      expect(File.exist?(path)).to be true
      expect(Process).not_to have_received(:spawn)
    end
  end

  describe '#cleanup_input' do
    it 'removes only the files of the input inside the working directory' do
      worker.instance_variable_set(:@dir, dir)
      inside  = File.join(dir, 'video.mp4').tap { File.write(_1, '') }
      thumb   = File.join(dir, 'thumb.jpg').tap { File.write(_1, '') }
      outside = Tempfile.create('outside') { |file| file.path.tap { |path| File.write(path, '') } }
      input   = SymMash.new(fn_in: inside, fn_out: outside, thumb: thumb, uploads: [SymMash.new(fn_out: File.join(dir, 'part.mp4'))])
      File.write(File.join(dir, 'part.mp4'), '')

      worker.cleanup_input(input)

      expect(Dir.children(dir)).to be_empty
    end
  end

  describe 'the status line' do
    it 'falls back to plain text when the formatted status cannot be edited' do
      worker.send(:init_status)
      worker.st.add('working') do |line|
        service.failing_edits = 1
        line.keep.update 'step_one'
      end

      id, params = service.edited.last
      expect(id).to eq 789
      expect(params).to include(parse_mode: nil, text: 'step_one')
    end

    it 'falls back to plain text when the cancel control cannot be removed with formatting' do
      worker.send(:init_status)
      worker.st.add('working') { |line| line.keep.update 'step_one' }
      service.failing_edits = 1
      worker.send(:clear_cancel_button)

      expect(service.edited.last.last).to include(parse_mode: nil, cancel_job: false, force: true)
    end

    it 'is deleted when it empties' do
      worker.send(:init_status)
      worker.st.add('working') { |line| line.update 'step_one' }

      expect(service.deleted).to eq [[789, {wait: 0}]]
    end
  end

  describe '#process' do
    it 'tells the user when there is nothing to process' do
      allow(Processors::Router).to receive(:for_message).and_return(nil)

      worker.process

      expect(service.edited.map { |_, params| params[:text] }).to include('No URL or media provided')
    end

    it 'reports an unexpected failure' do
      allow(worker).to receive(:run).and_raise(IOError, 'boom')

      worker.process

      expect(service.errors.map(&:message)).to eq ['boom']
    end
  end

  describe 'a failing input' do
    let(:uploader) { instance_double(Worker::UploadCoordinator, upload_or_queue: nil) }
    let(:input)    { SymMash.new(info: {title: 'Clip'}) }

    def process_failing(error)
      processor = double(download_one: nil)
      allow(processor).to receive(:download_one).and_raise(error)
      allow(processor).to receive(:stl=)
      input.processor = processor
      worker.send(:init_status)
      queue = [0]
      worker.process_input(input, pos: 0, total: 1, ordered: false, up_queue: queue, uploader: uploader)
      queue
    end

    it 'shows the message meant for the user and moves on' do
      error = Class.new(StandardError) { def user_message = 'Video unavailable' }.new('internal')

      expect(process_failing(error)).to be_empty
      expect(service.errors).to eq [error]
      expect(service.edited.map { |_, params| params[:text] }.join).to include('Video unavailable')
    end

    it 'shows a generic processing error otherwise' do
      error = IOError.new('closed stream')

      expect(process_failing(error)).to be_empty
      expect(service.errors).to eq [error]
      expect(service.edited.map { |_, params| params[:text] }.join).to include('Processing error')
    end
  end

  describe 'captions' do
    it 'uses the media caption limit when the service has none' do
      expect(worker.caption_limit).to eq Bot::MsgHelpers::MEDIA_CAPTION_LIMIT
    end

    it 'uses the limit of the service' do
      allow(service).to receive(:max_caption).and_return(4096)

      expect(worker.caption_limit).to eq 4096
    end

    it 'shares the limit between the items of an album' do
      allow(service).to receive(:max_caption).and_return(100)
      inputs = Array.new(2) { SymMash.new }
      allow(worker).to receive(:caption_for) { |_input, max:| "caption of #{max}" }

      expect(worker.album_caption(inputs)).to eq "caption of 49\n\ncaption of 49"
    end
  end
end
