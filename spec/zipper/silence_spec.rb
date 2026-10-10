require 'rails_helper'

RSpec.describe Zipper::Silence do
  include FFmpegDouble

  it 'creates cached pauses through FFmpeg semantic silence construction' do
    Dir.mktmpdir('pause-spec-') do |dir|
      ffmpeg = ffmpeg_double
      allow(ffmpeg).to receive(:create_silence) do |arguments|
        File.write arguments.fetch(:output), 'silence'
        arguments.fetch(:output)
      end

      path = described_class.pause 0.1, dir, sample_rate: 24_000, ffmpeg: ffmpeg

      expect(path).to end_with 'pause_0_1_24000.wav'
      expect(ffmpeg).to have_received(:create_silence).with(
        output: path,
        source_sample_rate: 24_000,
        duration: 0.1,
        filter: nil,
        amplitude: nil,
        sample_rate: nil,
        channels: nil,
        channel_layout: nil,
        codec: nil,
        codec_profile: nil,
        bitrate: nil,
        sample_format: nil,
        label: 'Failed to create silent audio file'
      )
    end
  end

  it 'passes noise-source semantics for amplitude pauses' do
    Dir.mktmpdir('pause-noise-spec-') do |dir|
      ffmpeg = ffmpeg_double
      allow(ffmpeg).to receive(:create_silence) do |arguments|
        File.write arguments.fetch(:output), 'silence'
        arguments.fetch(:output)
      end

      path = described_class.pause 3.5, dir, sample_rate: 24_000,
                                             extension: '.m4a', amplitude: 0.001, ffmpeg: ffmpeg

      expect(path).to end_with 'pause_3_5_24000_0_001.m4a'
      expect(ffmpeg).to have_received(:create_silence).with(
        output: path,
        source_sample_rate: 24_000,
        duration: 3.5,
        filter: 'lowpass=f=6000',
        amplitude: 0.001,
        sample_rate: nil,
        channels: nil,
        channel_layout: nil,
        codec: nil,
        codec_profile: nil,
        bitrate: nil,
        sample_format: nil,
        label: 'Failed to create silent audio file'
      )
    end
  end

  it 'passes input format policy as semantic pause arguments' do
    Dir.mktmpdir('formatted-pause-spec-') do |dir|
      ffmpeg = ffmpeg_double
      allow(ffmpeg).to receive(:create_silence) do |arguments|
        File.write arguments.fetch(:output), 'silence'
        arguments.fetch(:output)
      end
      format = {
        codec_name:      'pcm_s16le',
        sample_fmt:      's16',
        sample_rate:     24_000,
        channels:        2,
        channel_layout:  'stereo',
        bits_per_sample: 16,
      }

      path = described_class.pause 3.5, dir, format: format, extension: '.wav', ffmpeg: ffmpeg

      expect(path).to match(%r{/pause_3_5_24000_[0-9a-f]{12}\.wav\z})
      expect(ffmpeg).to have_received(:create_silence).with(
        output: path,
        source_sample_rate: 24_000,
        duration: 3.5,
        filter: nil,
        amplitude: nil,
        sample_rate: 24_000,
        channels: 2,
        channel_layout: 'stereo',
        codec: 'pcm_s16le',
        codec_profile: nil,
        bitrate: nil,
        sample_format: 's16',
        label: 'Failed to create silent audio file'
      )
    end
  end

  it 'preserves AAC pause profile and bitrate policy' do
    Dir.mktmpdir('aac-pause-spec-') do |dir|
      ffmpeg = ffmpeg_double
      allow(ffmpeg).to receive(:create_silence) do |arguments|
        File.write arguments.fetch(:output), 'silence'
        arguments.fetch(:output)
      end
      allow(FFmpeg).to receive(:fdk_aac_available?).and_return true
      format = {
        codec_name:     'aac',
        profile:        'HE-AAC',
        sample_rate:    24_000,
        channels:       2,
        channel_layout: 'stereo',
        bit_rate:       32_004,
      }

      path = described_class.pause 3.5, dir, format: format, extension: '.m4a', ffmpeg: ffmpeg

      expect(ffmpeg).to have_received(:create_silence).with(
        output: path,
        source_sample_rate: 24_000,
        duration: 3.5,
        filter: nil,
        amplitude: nil,
        sample_rate: 24_000,
        channels: 2,
        channel_layout: 'stereo',
        codec: 'libfdk_aac',
        codec_profile: 'aac_he',
        bitrate: 32_004,
        sample_format: nil,
        label: 'Failed to create silent audio file'
      )
    end
  end

  it 'does not encode unavailable FDK HE-AAC pauses' do
    Dir.mktmpdir('aac-pause-unavailable-spec-') do |dir|
      ffmpeg = ffmpeg_double
      allow(ffmpeg).to receive(:create_silence) do |arguments|
        File.write arguments.fetch(:output), 'silence'
        arguments.fetch(:output)
      end
      allow(FFmpeg).to receive(:fdk_aac_available?).and_return false
      format = {
        codec_name:     'aac',
        profile:        'HE-AAC',
        sample_rate:    24_000,
        channels:       2,
        channel_layout: 'stereo',
        bit_rate:       32_004,
      }

      path = described_class.pause 3.5, dir, format: format, extension: '.m4a', ffmpeg: ffmpeg

      expect(ffmpeg).to have_received(:create_silence).with(
        output: path,
        source_sample_rate: 24_000,
        duration: 3.5,
        filter: nil,
        amplitude: nil,
        sample_rate: 24_000,
        channels: 2,
        channel_layout: 'stereo',
        codec: nil,
        codec_profile: nil,
        bitrate: nil,
        sample_format: nil,
        label: 'Failed to create silent audio file'
      )
    end
  end

  it 'uses the returned pause encoding fields without repeating capability detection' do
    Dir.mktmpdir('semantic-pause-spec-') do |dir|
      ffmpeg = ffmpeg_double
      allow(ffmpeg).to receive(:create_silence) do |arguments|
        File.write arguments.fetch(:output), 'silence'
        arguments.fetch(:output)
      end
      format = {
        codec_name:     'aac',
        profile:        'HE-AAC',
        sample_rate:    24_000,
        channels:       2,
        channel_layout: 'stereo',
        bit_rate:       32_004,
      }
      encoding = FFmpeg::PauseEncoding.new(
        codec: 'libfdk_aac', profile: 'aac_he', bitrate: 32_004, sample_format: nil
      )
      expect(FFmpeg).to receive(:pause_encoding).with(format).once.and_return encoding

      path = File.join dir, 'silence.m4a'
      described_class.file path, 3.5, format: format, ffmpeg: ffmpeg

      expect(ffmpeg).to have_received(:create_silence).with(
        output: path,
        source_sample_rate: 24_000,
        duration: 3.5,
        filter: nil,
        amplitude: nil,
        sample_rate: 24_000,
        channels: 2,
        channel_layout: 'stereo',
        codec: 'libfdk_aac',
        codec_profile: 'aac_he',
        bitrate: 32_004,
        sample_format: nil,
        label: 'Failed to create silent audio file'
      )
    end
  end

  it 'creates each cached pause file only once across concurrent callers' do
    Dir.mktmpdir('pause-concurrency-spec-') do |dir|
      ffmpeg = ffmpeg_double
      runs = 0
      runs_mutex = Mutex.new
      allow(ffmpeg).to receive(:create_silence) do |arguments|
        runs_mutex.synchronize { runs += 1 }
        sleep 0.05
        File.write arguments.fetch(:output), 'silence'
        arguments.fetch(:output)
      end

      threads = 4.times.map do
        Thread.new do
          described_class.pause 0.1, dir, sample_rate: 24_000, ffmpeg: ffmpeg
        end
      end

      expect(threads.map(&:value).uniq).to contain_exactly File.join(dir, 'pause_0_1_24000.wav')
      expect(runs).to eq 1
      expect(ffmpeg).to have_received(:create_silence).once
    end
  end
end
