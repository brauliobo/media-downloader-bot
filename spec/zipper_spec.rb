require 'spec_helper'

RSpec.describe Zipper do
  it 'uses CUDA decode before the input when CUDA encoding is enabled' do
    probe = SymMash.new(
      format: SymMash.new(duration: 60),
      streams: [SymMash.new(codec_type: 'video', width: 1920, height: 1080)],
    )
    opts = SymMash.new(
      cuda: 1,
      format: Zipper::Types.video.h264,
      acodec: 'aac',
      metadata: {},
    )

    allow(Sh).to receive(:run)

    described_class.new('/tmp/in.mp4', '/tmp/out.mp4', probe: probe, opts: opts).zip_video

    expect(Sh).to have_received(:run).with(include('-hwaccel cuda -i /tmp/in.mp4'))
  end

  it 'keeps NVENC but skips CUDA decode when mpdecimate is used' do
    probe = SymMash.new(
      format: SymMash.new(duration: 60),
      streams: [SymMash.new(codec_type: 'video', width: 1920, height: 1080)],
    )
    opts = SymMash.new(
      cuda: 1,
      vf: 'mpdecimate=hi=1024:lo=512:frac=0.40',
      format: Zipper::Types.video.h264,
      acodec: 'aac',
      metadata: {},
    )

    allow(Sh).to receive(:run)

    described_class.new('/tmp/in.mp4', '/tmp/out.mp4', probe: probe, opts: opts).zip_video

    expect(Sh).to have_received(:run).with(include('-i /tmp/in.mp4'))
    expect(Sh).to have_received(:run).with(include('-c:v h264_nvenc'))
    expect(Sh).not_to have_received(:run).with(include('-hwaccel cuda'))
  end

  it 'does not scale camera-preserved video with encoder-safe dimensions' do
    probe = SymMash.new(
      format: SymMash.new(duration: 60),
      streams: [SymMash.new(codec_type: 'video', width: 1920, height: 1080)],
    )
    opts = SymMash.new(
      cuda: 1,
      preserve_resolution: 1,
      vf: 'mpdecimate=hi=1024:lo=512:frac=0.40',
      format: Zipper::Types.video.h264,
      acodec: 'aac',
      metadata: {},
    )

    allow(Sh).to receive(:run)

    described_class.new('/tmp/in.mp4', '/tmp/out.mp4', probe: probe, opts: opts).zip_video

    expect(Sh).to have_received(:run).with(include('-filter_complex "mpdecimate=hi=1024:lo=512:frac=0.40,format=yuv420p"'))
    expect(Sh).not_to have_received(:run).with(include('scale='))
  end
end
