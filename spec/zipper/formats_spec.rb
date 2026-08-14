require 'spec_helper'

RSpec.describe Zipper::Formats do
  describe 'domain projections' do
    it 'projects the FFmpeg encoder profiles through the historical format API' do
      expect(described_class::VIDEO_PROFILES).to equal FFmpeg::VIDEO_ENCODERS
      expect(described_class::AUDIO_PROFILES).to equal FFmpeg::AUDIO_ENCODERS
      expect(Zipper::Types.video.h264.opts).to include(width: 720, quality: 25, abrate: 64)
      expect(Zipper::Types.audio.opus.opts).to include(bitrate: 96, percent: 0.95)
      expect(Zipper::Types.video.h264).to include(
        codec_cpu: 'libx264', qflag_cuda: '-cq', preset_cuda: 'p4'
      )
      expect(Zipper::Types.video.h264.extra_cuda).to include(
        '-spatial-aq 1', '-temporal-aq 1', '-b:v 0'
      )
      expect(Zipper::Types.audio.opus.encode).to eq(
        '-ac 1 -ar 48000 -c:a libopus -b:a %{abrate}k'
      )
      expect(described_class::AUDIO_ENC.opus.encode).to eq Zipper::Types.audio.opus.encode
      expect(Zipper::AUDIO_ENC).to equal described_class::AUDIO_ENC
      expect([true, false]).to include described_class::FDK_AAC
      expect(Zipper::Types.video.av1.extra_cuda).to eq '-preset p6'
      expect(Zipper::Types.video.vp9.qflag_cpu).to eq ''
    end

    it 'keeps encoder behavior in FFmpeg profiles' do
      expect(FFmpeg::VIDEO_ENCODERS[:h264]).to include(
        codec_cpu: 'libx264', codec_cuda: 'h264_nvenc', quality_cpu: :crf,
        quality_cuda: :cq, preset_cuda: 'p4'
      )
      expect(FFmpeg::VIDEO_ENCODERS[:h265]).to include(
        codec_cuda: 'hevc_nvenc', preset_cuda: 'p5', multipass_cuda: 'qres'
      )
      expect(FFmpeg::VIDEO_ENCODERS[:av1]).to include(codec_cpu: 'libaom-av1')
      expect(FFmpeg::VIDEO_ENCODERS[:vp9]).to include(codec_cpu: 'libvpx-vp9')
      expect(FFmpeg::AUDIO_ENCODERS[:opus]).to include(codec: 'libopus', bitrate: 96)
    end
  end

  describe '.choose_format' do
    it 'uses the long default for long videos under CUDA' do
      chosen = described_class.choose_format Zipper::Types.video, SymMash.new(cuda: true), 700

      expect(chosen).to eq Zipper::Types.video.h265
    end

    it 'falls back to the short default for long videos without CUDA' do
      chosen = described_class.choose_format Zipper::Types.video, SymMash.new, 700

      expect(chosen).to eq Zipper::Types.video.h264
    end

    it 'uses the short default for short videos' do
      chosen = described_class.choose_format Zipper::Types.video, SymMash.new, 60

      expect(chosen).to eq Zipper::Types.video.h264
    end

    it 'does not apply long-default selection to audio' do
      chosen = described_class.choose_format Zipper::Types.audio, SymMash.new(audio: 1), 700

      expect(chosen).to eq Zipper::Types.audio.opus
    end

    it 'maps common container aliases' do
      expect(described_class.choose_format(Zipper::Types.video, SymMash.new(format: 'mp4'), 60))
        .to eq Zipper::Types.video.h264
      expect(described_class.choose_format(Zipper::Types.audio, SymMash.new(format: 'm4a'), 60))
        .to eq Zipper::Types.audio.aac
    end

    it 'falls back to the default for unknown user-provided formats' do
      chosen = described_class.choose_format Zipper::Types.video, SymMash.new(format: 'bogus'), 60

      expect(chosen).to eq Zipper::Types.video.h264
    end

    it 'upgrades short opus to AAC when a size limit is set' do
      Zipper.size_mb_limit = 50

      expect(described_class.choose_format(Zipper::Types.audio, SymMash.new, 60))
        .to eq Zipper::Types.audio.aac
    ensure
      Zipper.size_mb_limit = nil
    end
  end
end
