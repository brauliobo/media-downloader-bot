require 'spec_helper'

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
    four_month_path = "/mnt/big_data/Camera/cam-#{(Date.today - 100).strftime('%Y%m%d')}_000000.mp4"
    five_month_path = "/mnt/big_data/Camera/cam-#{(Date.today - 150).strftime('%Y%m%d')}_000000.mp4"
    archive_path = "/mnt/big_data/Camera/cam-#{(Date.today - 181).strftime('%Y%m%d')}_000000.mp4"

    recent = SymMash.new(camera: 1)
    four_month = SymMash.new(camera: 1)
    five_month = SymMash.new(camera: 1)
    archive = SymMash.new(camera: 1)

    described_class.apply(recent, path: recent_path)
    described_class.apply(four_month, path: four_month_path)
    described_class.apply(five_month, path: five_month_path)
    described_class.apply(archive, path: archive_path)

    expect(recent.vf).to eq('mpdecimate=hi=1024:lo=512:frac=0.40')
    expect(recent.abrate).to eq('32')
    expect(four_month.vf).to eq('mpdecimate=hi=3072:lo=1536:frac=0.60')
    expect(four_month.abrate).to eq('12')
    expect(five_month.vf).to eq('mpdecimate=hi=4096:lo=2048:frac=0.70')
    expect(five_month.abrate).to eq('12')
    expect(archive.keyframes).to eq(1)
    expect(archive.mpdecimate).to eq('hi=6144:lo=3072:frac=0.80')
    expect(archive.noaudio).to eq(1)
  end
end
