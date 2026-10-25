require 'rails_helper'
require_relative '../support/media_files'
require 'tmpdir'
require 'fileutils'

RSpec.describe Presets::Camera do
  it 'applies camera compression defaults without overriding explicit opts' do
    opts = SymMash.new(camera: 1, quality: 24)

    described_class.apply(opts)

    expect(opts.cudaenc).to eq(1)
    expect(opts.format).to eq('h264')
    expect(opts.quality).to eq(24)
    expect(opts.acodec).to eq('aac')
    expect(opts.preserve_resolution).to eq(1)
    expect(opts.delete_originals).to eq(1)
  end

  it 'records generated option args for CLI delegation' do
    opts = SymMash.new(camera: 1)
    option_args = %w[camera]

    described_class.apply(opts, option_args: option_args)

    expect(option_args).to include(
      'cudaenc',
      'format=h264',
      'quality=32',
      'acodec=aac',
      'preserve_resolution',
      'delete_originals',
    )
  end

  it 'applies progressive camera tiers from file age' do
    recent_path = "/mnt/big_data/Camera/cam-#{Date.today.strftime('%Y%m%d')}_000000.mp4"
    archive_path = "/mnt/big_data/Camera/cam-#{(Date.today - 91).strftime('%Y%m%d')}_000000.mp4"

    recent = SymMash.new(camera: 1)
    archive = SymMash.new(camera: 1)

    described_class.apply(recent, path: recent_path)
    described_class.apply(archive, path: archive_path)

    expect(recent.vf).to eq('mpdecimate=hi=1024:lo=512:frac=0.40')
    expect(recent.abrate).to eq('32')
    expect(archive.keyframes).to eq(1)
    expect(archive.mpdecimate).to eq('hi=6144:lo=3072:frac=0.80')
    expect(archive.noaudio).to eq(1)
  end

  describe '.converted?' do
    include MediaFiles

    def stamped(dir, age, tier)
      name = "cam-#{(Date.today - age).strftime('%Y%m%d')}_000000.mp4"
      File.join(dir, name).tap do |path|
        media_file(path, as: :busy_mp4)
        tagged = path.sub('.mp4', '-tagged.mp4')
        system('ffmpeg', '-v', 'error', '-y', '-i', path, '-c', 'copy', '-metadata', "comment=mediazip:#{tier}", tagged, exception: true)
        FileUtils.mv(tagged, path)
      end
    end

    it 'is done when stamped with the tier of its age or a stricter one, or already under the bitrate ceiling' do
      Dir.mktmpdir do |dir|
        expect(described_class.converted?(stamped(dir, 70, 1))).to be false
        expect(described_class.converted?(stamped(dir, 70, 2))).to be true
        expect(described_class.converted?(media_file(File.join(dir, "cam-#{Date.today.strftime('%Y%m%d')}_000000.mp4"), as: :busy_mp4))).to be false
        expect(described_class.converted?(media_file(File.join(dir, "cam-#{Date.today.strftime('%Y%m%d')}_000001.mp4")))).to be true
      end
    end
  end
end
