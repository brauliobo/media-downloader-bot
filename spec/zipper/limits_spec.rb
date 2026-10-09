require 'rails_helper'

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

  it 'reduces long audio bitrate to fit the Telegram limit' do
    Zipper.size_mb_limit = 50
    opts   = SymMash.new(onlysrt: false, bitrate: 96, percent: 0.95)
    zipper = Struct.new(:opts, :duration).new(opts, 4_506)

    described_class.apply_audio_size_limit! zipper

    expect(opts.bitrate).to be_within(0.001).of(84.332)
  end

  it 'never lowers the dynamic audio bitrate below the minimum' do
    Zipper.size_mb_limit = 50
    opts   = SymMash.new(onlysrt: false, bitrate: 96, percent: 0.95)
    zipper = Struct.new(:opts, :duration).new(opts, 40_000)

    described_class.apply_audio_size_limit! zipper

    expect(opts.bitrate).to eq(described_class::MIN_AUDIO_BITRATE_KBIT)
  end

  it 'calculates the longest audio that fits at the minimum bitrate' do
    expect(described_class.max_encoded_duration(:audio, 50)).to be_within(0.001).of(23_750)
    expect(described_class.max_encoded_duration(:audio, 2_000)).to be_within(0.001).of(950_000)
  end

  it 'calculates the longest video that fits at the minimum bitrates' do
    expect(described_class.max_encoded_duration(:video, 50)).to be_within(0.01).of(2_605.263)
    expect(described_class.max_encoded_duration(:video, 2_000)).to be_within(0.01).of(104_210.526)
  end

  it 'never lowers the dynamic video bitrate below the minimum' do
    Zipper.size_mb_limit = 50
    opts = SymMash.new(
      onlysrt: false, width: 720, abrate: 64, percent: 0.99, vbrate: nil, cudaenc: false
    )
    zipper = instance_double(
      Zipper, opts: opts, dopts: SymMash.new(width: 720, abrate: 64), duration: 2_600, format_name: :h264
    )

    result = described_class.apply_video_size_limits! zipper

    expect(result.maxrate).to eq("#{described_class::MIN_VIDEO_BITRATE_KBIT}k")
    expect(opts.width).to eq(480)
    expect(opts.abrate).to eq(40)
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
