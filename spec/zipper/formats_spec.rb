require 'spec_helper'

RSpec.describe Zipper::Formats do
  describe '.choose_format' do
    it 'uses the long default for long videos under CUDA' do
      chosen = described_class.choose_format(Zipper::Types.video, SymMash.new(cuda: true), 700)

      expect(chosen).to eq(Zipper::Types.video.h265)
    end

    it 'falls back to the short default for long videos without CUDA' do
      chosen = described_class.choose_format(Zipper::Types.video, SymMash.new, 700)

      expect(chosen).to eq(Zipper::Types.video.h264)
    end

    it 'uses the short default for short videos' do
      chosen = described_class.choose_format(Zipper::Types.video, SymMash.new, 60)

      expect(chosen).to eq(Zipper::Types.video.h264)
    end

    it 'does not apply long-default selection to audio' do
      chosen = described_class.choose_format(Zipper::Types.audio, SymMash.new(audio: 1), 700)

      expect(chosen).to eq(Zipper::Types.audio.opus)
    end

    it 'maps mp4 alias to h264 for video' do
      chosen = described_class.choose_format(Zipper::Types.video, SymMash.new(format: 'mp4'), 60)

      expect(chosen).to eq(Zipper::Types.video.h264)
    end

    it 'maps m4a alias to aac for audio' do
      chosen = described_class.choose_format(Zipper::Types.audio, SymMash.new(format: 'm4a'), 60)

      expect(chosen).to eq(Zipper::Types.audio.aac)
    end

    it 'falls back to default for unknown user-provided format' do
      chosen = described_class.choose_format(Zipper::Types.video, SymMash.new(format: 'bogus'), 60)

      expect(chosen).to eq(Zipper::Types.video.h264)
    end

    it 'upgrades short opus to aac when size_mb_limit is set' do
      begin
        Zipper.size_mb_limit = 50
        chosen = described_class.choose_format(Zipper::Types.audio, SymMash.new, 60)
        expect(chosen).to eq(Zipper::Types.audio.aac)
      ensure
        Zipper.size_mb_limit = nil
      end
    end

    it 'uses NVENC constant-quality flags for CUDA h264' do
      expect(Zipper::Types.video.h264.qflag_cuda).to eq('-cq')
      expect(Zipper::Types.video.h264.extra_cuda).to include('-b:v 0')
    end

    it 'uses a higher-quality NVENC preset for CUDA h265' do
      expect(Zipper::Types.video.h265.preset_cuda).to eq('p5')
      expect(Zipper::Types.video.h265.extra_cuda).to include('-spatial_aq 1')
    end
  end
end
