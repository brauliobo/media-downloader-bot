require 'rails_helper'

RSpec.describe Zipper::AudioOps do
  include FFmpegDouble

  it 'cleans a temporary wav after yielding it through an injected builder' do
    ffmpeg = ffmpeg_double
    output = nil
    allow(ffmpeg).to receive(:audio_to_wav) do |arguments|
      output = arguments.fetch(:output)
      File.write output, 'wav'
      output
    end

    result = described_class.with_wav '/tmp/input.mp4', sample_rate: 16_000, channels: 1,
                                            ffmpeg: ffmpeg do |file|
      file.read
    end

    expect(result).to eq 'wav'
    expect(File).not_to exist(output)
    expect(ffmpeg).to have_received(:audio_to_wav).with(
      input: '/tmp/input.mp4', output: match(/audio-.*\.wav\z/),
      sample_rate: 16_000, channels: 1, label: 'ffmpeg failed'
    )
  end

  it 'cleans a stream-copied audio file after yielding it through an injected builder' do
    ffmpeg = ffmpeg_double
    output = nil
    allow(ffmpeg).to receive(:extract_copy_audio) do |arguments|
      output = arguments.fetch(:output)
      File.write output, 'audio'
      output
    end

    result = described_class.with_copy '/tmp/input.mp4', ffmpeg: ffmpeg do |file|
      file.read
    end

    expect(result).to eq 'audio'
    expect(File).not_to exist(output)
    expect(ffmpeg).to have_received(:extract_copy_audio).with(
      input: '/tmp/input.mp4', output: match(/audio-.*\.mka\z/), label: 'ffmpeg failed'
    )
  end

  it 'preserves single-input copy compatibility and uses semantic concat for multiple inputs' do
    Dir.mktmpdir('concat-spec-') do |dir|
      one = File.join dir, 'one.wav'
      output = File.join dir, 'out.wav'
      File.write one, 'one'
      expect(described_class.concat([one], output)).to be_nil
      expect(File.read(output)).to eq 'one'

      ffmpeg = ffmpeg_double
      signature = {codec_name: 'pcm_s16le', sample_rate: 24_000, channels: 1}
      allow(Prober).to receive(:audio_signature).and_return signature
      described_class.concat %w[first.wav second.wav], '/tmp/out.wav', ffmpeg: ffmpeg

      expect(ffmpeg).to have_received(:concat_audio).with(
        inputs: match(%r{/concat\.txt\z}), output: '/tmp/out.wav', copy: true,
        label: 'FFmpeg concat failed'
      )
    end
  end

  it 'uses semantic concat inputs and the highest sample rate when re-encoding' do
    ffmpeg = ffmpeg_double
    allow(Prober).to receive(:audio_signature) do |path, ffmpeg:|
      {codec_name: 'pcm_s16le', sample_rate: path.include?('pause') ? 22_050 : 24_000}
    end

    described_class.concat %w[/tmp/pause.wav /tmp/speech.wav], '/tmp/out.wav', ffmpeg: ffmpeg

    expect(ffmpeg).to have_received(:concat_audio).with(
      inputs: %w[/tmp/pause.wav /tmp/speech.wav], output: '/tmp/out.wav', copy: false,
      sample_rate: 24_000, label: 'FFmpeg concat failed'
    )
  end

  it 'preserves the concat error label' do
    ffmpeg = ffmpeg_double
    allow(Prober).to receive(:audio_signature).and_return({codec_name: 'pcm_s16le', sample_rate: 24_000})
    allow(ffmpeg).to receive(:concat_audio).and_raise Sh::Error.new('FFmpeg concat failed', 'invalid audio')

    expect {
      described_class.concat %w[first.wav second.wav], '/tmp/out.wav', ffmpeg: ffmpeg
    }.to raise_error 'FFmpeg concat failed'
  end

  it 'delegates floor and speed operations while preserving temporary moves' do
    Dir.mktmpdir('audio-helper-spec-') do |dir|
      source = File.join dir, 'speech.wav'
      File.write source, 'speech'
      ffmpeg = ffmpeg_double
      allow(ffmpeg).to receive(:add_audio_floor) do |arguments|
        File.write arguments.fetch(:output), 'speech with floor'
        arguments.fetch(:output)
      end
      allow(ffmpeg).to receive(:speed_audio) do |arguments|
        File.write arguments.fetch(:output), 'sped'
        arguments.fetch(:output)
      end

      expect(described_class.add_floor!(
        source, amplitude: 0.001, loudness_lufs: -18, sample_rate: 24_000, ffmpeg: ffmpeg
      )).to eq source
      expect(File.read(source)).to eq 'speech with floor'
      expect(ffmpeg).to have_received(:add_audio_floor).with(
        input: source, amplitude: 0.001, loudness_lufs: -18,
        output: match(%r{/audio_floor_.*\.wav\z}),
        sample_rate: 24_000, label: 'Failed to add audiobook audio floor'
      )

      expect(described_class.speed!(source, 1.2, ffmpeg: ffmpeg)).to eq source
      expect(File.read(source)).to eq 'sped'
      expect(ffmpeg).to have_received(:speed_audio).with(
        input: source, output: match(%r{/speed_.*\.wav\z}),
        filter: match(/rubberband=tempo=1\.2.*formant=preserved/),
        label: 'Failed to apply audio speed'
      )
    end
  end

  it 'preserves the WAV conversion error label' do
    ffmpeg = ffmpeg_double
    allow(ffmpeg).to receive(:audio_to_wav).and_raise Sh::Error.new('ffmpeg failed', 'invalid audio')

    expect {
      described_class.to_wav '/tmp/input.mp4', ffmpeg: ffmpeg
    }.to raise_error 'ffmpeg failed'
  end
end
