require 'spec_helper'
require_relative '../support/integration_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Processors::Folder do
  let(:media_fixture) { IntegrationHelper.ensure_fixtures[:mp4] }

  def write_media(path)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.cp(media_fixture, path)
  end

  def write_replacement_media(path)
    write_media(path)
    File.open(path, 'ab') { |file| file.write('replacement-marker') }
  end

  describe '.handles?' do
    it 'handles directory inputs without requiring a camera option' do
      Dir.mktmpdir do |dir|
        expect(described_class.handles?([dir], SymMash.new)).to be_truthy
      end
    end

    it 'leaves ordinary file inputs to bin/zip' do
      expect(described_class.handles?(['/tmp/file.mp4'], SymMash.new)).to be_falsey
    end
  end

  describe '#run' do
    it 'prints a review with nested output directories' do
      Dir.mktmpdir do |dir|
        folder = File.join(dir, 'Media')
        FileUtils.mkdir_p File.join(folder, 'nested')
        video = File.join(folder, 'nested', 'clip.MP4')
        text = File.join(folder, 'notes.txt')
        write_media(video)
        File.write(text, '')

        opts = SymMash.new(review: 1, metadata: {})
        option_args = %w[review]
        converted_dir = File.join(dir, 'converted')

        processor = described_class.new(
          paths: [folder],
          opts: opts,
          option_args: option_args,
          bot: Bot::Mock.new,
        )

        expect { processor.run }.to output(
          include(
            'folder media processing review',
            'inputs: 1 media file(s)',
            "options: #{option_args.join(' ')}",
            "#{video} -> #{File.join(folder, 'nested', 'converted')}",
          ),
        ).to_stdout
      end
    end

    it 'skips empty media files' do
      Dir.mktmpdir do |dir|
        empty = File.join(dir, 'empty.mp4')
        full = File.join(dir, 'full.mp4')
        File.write(empty, '')
        write_media(full)

        processor = described_class.new(
          paths: [dir],
          opts: SymMash.new(review: 1, metadata: {}),
          option_args: %w[review],
          bot: Bot::Mock.new,
        )

        output = StringIO.new
        original_stdout = $stdout
        begin
          $stdout = output
          processor.run
        ensure
          $stdout = original_stdout
        end

        expect(output.string).to include('inputs: 1 media file(s)', full)
        expect(output.string).not_to include(empty)
      end
    end

    it 'applies camera preset when camera mode is requested' do
      Dir.mktmpdir do |dir|
        folder = File.join(dir, 'Camera')
        FileUtils.mkdir_p folder
        write_media(File.join(folder, 'clip.mp4'))

        opts = SymMash.new(camera: 1, review: 1, metadata: {})
        option_args = %w[camera review]

        processor = described_class.new(
          paths: [folder],
          opts: opts,
          option_args: option_args,
          bot: Bot::Mock.new,
        )

        expect { processor.run }.to output(
          include('cudaenc format=h264 quality=32 acodec=aac preserve_resolution delete_originals'),
        ).to_stdout
      end
    end

    it 'adds camera age tier options per file' do
      Dir.mktmpdir do |dir|
        folder = File.join(dir, 'Camera')
        FileUtils.mkdir_p folder
        recent = File.join(folder, "#{Date.today.strftime('%Y%m%d')}_000000.mp4")
        old = File.join(folder, '20250901_000000.mp4')
        write_media(recent)
        write_media(old)

        opts = SymMash.new(camera: 1, metadata: {})
        processor = described_class.new(
          paths: [folder],
          opts: opts,
          option_args: %w[camera],
          bot: Bot::Mock.new,
        )

        attached = []
        allow(Processors::LocalFile).to receive(:attach_to_message) { |_msg, path, opts:| attached << [path, opts] }
        allow_any_instance_of(Worker).to receive(:process)

        processor.run

        recent_opts = attached.assoc(recent).last
        old_opts = attached.assoc(old).last
        expect(recent_opts).to include('vf=mpdecimate=hi=1024:lo=512:frac=0.40', 'abrate=32')
        expect(old_opts).to include('keyframes', 'mpdecimate=hi=6144:lo=3072:frac=0.80', 'noaudio')
      end
    end

    it 'does not delete the source when only another converted file was created' do
      Dir.mktmpdir do |dir|
        folder = File.join(dir, 'Camera')
        converted = File.join(folder, 'converted')
        FileUtils.mkdir_p converted
        source = File.join(folder, 'clip.mp4')
        other = File.join(converted, 'other.mp4')
        write_media(source)

        processor = described_class.new(
          paths: [folder],
          opts: SymMash.new(delete_originals: 1, metadata: {}),
          option_args: %w[delete_originals],
          bot: Bot::Mock.new,
        )

        allow_any_instance_of(Worker).to receive(:process) { write_media(other) }
        allow(Prober).to receive(:for).with(other).and_return(SymMash.new(format: SymMash.new(duration: 1)))

        processor.run

        expect(File.exist?(source)).to be true
      end
    end

    it 'uses jobs as folder processing concurrency' do
      Dir.mktmpdir do |dir|
        folder = File.join(dir, 'Camera')
        FileUtils.mkdir_p folder
        write_media(File.join(folder, 'a.mp4'))
        write_media(File.join(folder, 'b.mp4'))

        opts = SymMash.new(jobs: '2', metadata: {})
        processor = described_class.new(
          paths: [folder],
          opts: opts,
          option_args: %w[jobs=2],
          bot: Bot::Mock.new,
        )

        allow_any_instance_of(Worker).to receive(:process)
        expect_any_instance_of(Array).to receive(:peach).with(threads: 2).and_call_original

        processor.run
      end
    end

    it 'replaces originals in place when replace mode is enabled' do
      Dir.mktmpdir do |dir|
        folder = File.join(dir, 'Camera')
        FileUtils.mkdir_p folder
        source = File.join(folder, 'clip.mp4')
        write_media(source)

        processor = described_class.new(
          paths: [folder],
          opts: SymMash.new(replace: 1, metadata: {}),
          option_args: %w[replace],
          bot: Bot::Mock.new,
        )

        allow(Processors::LocalFile).to receive(:attach_to_message) do |_msg, input_path, opts:|
          expect(input_path).to eq(source)
          expect(opts).to include('replace')
        end
        allow_any_instance_of(Worker).to receive(:process) do
          output = File.join(folder, '.mediazip-replace', 'clip.mp4')
          write_replacement_media(output)
          FileUtils.touch(output, mtime: Time.now + 1)
        end
        allow(Prober).to receive(:for).with(File.join(folder, '.mediazip-replace', 'clip.mp4')).and_return(
          SymMash.new(format: SymMash.new(duration: 1))
        )

        processor.run

        expect(File.binread(source)).to include('replacement-marker')
        expect(File.exist?(File.join(folder, 'converted'))).to be false
      end
    end

    it 'does not delete originals after in-place replacement' do
      Dir.mktmpdir do |dir|
        source = File.join(dir, 'clip.mp4')
        write_media(source)

        processor = described_class.new(
          paths: [dir],
          opts: SymMash.new(replace: 1, delete_originals: 1, metadata: {}),
          option_args: %w[replace delete_originals],
          bot: Bot::Mock.new,
        )

        allow_any_instance_of(Worker).to receive(:process) do
          output = File.join(dir, '.mediazip-replace', 'clip.mp4')
          write_replacement_media(output)
          FileUtils.touch(output, mtime: Time.now + 1)
        end
        allow(Prober).to receive(:for).and_return(SymMash.new(format: SymMash.new(duration: 1)))
        allow(processor).to receive(:system)

        processor.run

        expect(File.binread(source)).to include('replacement-marker')
        expect(processor).not_to have_received(:system)
      end
    end

    it 'filters folder entries by age options' do
      Dir.mktmpdir do |dir|
        recent = File.join(dir, "#{Date.today.strftime('%Y%m%d')}_000000.mp4")
        old = File.join(dir, '20250901_000000.mp4')
        write_media(recent)
        write_media(old)

        processor = described_class.new(
          paths: [dir],
          opts: SymMash.new(review: 1, min_age: 91, metadata: {}),
          option_args: %w[review min_age=91],
          bot: Bot::Mock.new,
        )

        output = StringIO.new
        original_stdout = $stdout
        begin
          $stdout = output
          processor.run
        ensure
          $stdout = original_stdout
        end

        expect(output.string).to include(old)
        expect(output.string).not_to include(recent)
      end
    end

    it 'reviews replace mode as in-place output' do
      Dir.mktmpdir do |dir|
        video = File.join(dir, 'clip.mp4')
        write_media(video)

        processor = described_class.new(
          paths: [dir],
          opts: SymMash.new(replace: 1, review: 1, metadata: {}),
          option_args: %w[replace review],
          bot: Bot::Mock.new,
        )

        expect { processor.run }.to output(
          include('output: replace originals in place', "#{video} -> #{File.join(dir, '.mediazip-replace')}"),
        ).to_stdout
      end
    end

    it 'reports when original deletion fails' do
      Dir.mktmpdir do |dir|
        folder = File.join(dir, 'Camera')
        converted = File.join(folder, 'converted')
        FileUtils.mkdir_p converted
        source = File.join(folder, 'clip.mp4')
        output = File.join(converted, 'clip.mp4')
        write_media(source)

        processor = described_class.new(
          paths: [folder],
          opts: SymMash.new(delete_originals: 1, metadata: {}),
          option_args: %w[delete_originals],
          bot: Bot::Mock.new,
        )

        allow_any_instance_of(Worker).to receive(:process) do
          write_media(output)
          FileUtils.touch(output, mtime: Time.now + 1)
        end
        allow(Prober).to receive(:for).with(output).and_return(SymMash.new(format: SymMash.new(duration: 1)))
        allow_any_instance_of(described_class).to receive(:system).with('sudo', '-n', 'rm', '--', source).and_return(false)

        expect { processor.run }.to output(include('delete original failed:')).to_stdout
      end
    end
  end
end
