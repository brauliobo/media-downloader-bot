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
end
