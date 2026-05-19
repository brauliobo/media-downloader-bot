require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe Processors::Folder do
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
        File.write(video, '')
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

    it 'applies camera preset when camera mode is requested' do
      Dir.mktmpdir do |dir|
        folder = File.join(dir, 'Camera')
        FileUtils.mkdir_p folder
        File.write(File.join(folder, 'clip.mp4'), '')

        opts = SymMash.new(camera: 1, review: 1, metadata: {})
        option_args = %w[camera review]

        processor = described_class.new(
          paths: [folder],
          opts: opts,
          option_args: option_args,
          bot: Bot::Mock.new,
        )

        expect { processor.run }.to output(
          include('cuda format=h264 quality=32 acodec=aac abrate=32 vf=mpdecimate=hi=1024:lo=512:frac=0.40 preserve_resolution delete_originals'),
        ).to_stdout
      end
    end

    it 'does not delete the source when only another converted file was created' do
      Dir.mktmpdir do |dir|
        folder = File.join(dir, 'Camera')
        converted = File.join(folder, 'converted')
        FileUtils.mkdir_p converted
        source = File.join(folder, 'clip.mp4')
        other = File.join(converted, 'other.mp4')
        File.write(source, '')

        processor = described_class.new(
          paths: [folder],
          opts: SymMash.new(delete_originals: 1, metadata: {}),
          option_args: %w[delete_originals],
          bot: Bot::Mock.new,
        )

        allow_any_instance_of(Worker).to receive(:process) { File.write(other, 'converted') }
        allow(Prober).to receive(:for).with(other).and_return(SymMash.new(format: SymMash.new(duration: 1)))

        processor.run

        expect(File.exist?(source)).to be true
      end
    end

    it 'reports when original deletion fails' do
      Dir.mktmpdir do |dir|
        folder = File.join(dir, 'Camera')
        converted = File.join(folder, 'converted')
        FileUtils.mkdir_p converted
        source = File.join(folder, 'clip.mp4')
        output = File.join(converted, 'clip.mp4')
        File.write(source, '')

        processor = described_class.new(
          paths: [folder],
          opts: SymMash.new(delete_originals: 1, metadata: {}),
          option_args: %w[delete_originals],
          bot: Bot::Mock.new,
        )

        allow_any_instance_of(Worker).to receive(:process) do
          File.write(output, 'converted')
          FileUtils.touch(output, mtime: Time.now + 1)
        end
        allow(Prober).to receive(:for).with(output).and_return(SymMash.new(format: SymMash.new(duration: 1)))
        allow_any_instance_of(described_class).to receive(:system).with('sudo', '-n', 'rm', '--', source).and_return(false)

        expect { processor.run }.to output(include('delete original failed:')).to_stdout
      end
    end
  end
end
