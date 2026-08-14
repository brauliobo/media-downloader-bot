require 'spec_helper'

RSpec.describe Zipper::Limits do
  around do |example|
    original = Zipper.size_mb_limit
    example.run
  ensure
    Zipper.size_mb_limit = original
  end

  it 'owns audio and video duration threshold calculations' do
    expect(described_class.max_audio_duration(64, 50)).to be_within(0.001).of(104.167)
    expect(described_class.vid_duration_thld(50)).to eq(20)
    expect(described_class.vid_duration_thld(nil)).to eq(Float::INFINITY)
  end

  it 'backs the Zipper compatibility facade' do
    Zipper.size_mb_limit = 50

    expect(Zipper.max_audio_duration(64)).to eq(described_class.max_audio_duration(64, 50))
    expect(Zipper.vid_duration_thld).to eq(described_class.vid_duration_thld(50))
    expect(Zipper.aud_duration_thld).to eq(described_class.aud_duration_thld(50))
  end

  it 'returns semantic video size data with the existing calculations' do
    Zipper.size_mb_limit = 2_000
    opts = SymMash.new(
      onlysrt: false, width: 1_280, abrate: 64, percent: 0.99,
      vbrate: nil, cudaenc: true
    )
    zipper = instance_double(
      Zipper,
      opts: opts,
      dopts: SymMash.new(width: 1_920, abrate: 64),
      duration: 3_600,
      format_name: :h264
    )

    result = described_class.apply_video_size_limits! zipper

    expect(result).to eq described_class::VideoSize.new(
      maxrate: '4336k', bufsize: '1971M', rate_control: :vbr, bitrate: nil
    )
  end

  it 'returns a numeric VP9 bitrate for FFmpeg rate rendering' do
    Zipper.size_mb_limit = 2_000
    opts = SymMash.new(
      onlysrt: false, width: 1_280, abrate: 64, percent: 0.97,
      vbrate: nil, cudaenc: false
    )
    zipper = instance_double(
      Zipper,
      opts: opts,
      dopts: SymMash.new(width: 1_920, abrate: 64),
      duration: 3_600,
      format_name: :vp9
    )

    result = described_class.apply_video_size_limits! zipper

    expect(result).to eq described_class::VideoSize.new(
      maxrate: nil, bufsize: nil, rate_control: :vbr, bitrate: 4248
    )
  end
end
