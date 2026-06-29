require 'spec_helper'

RSpec.describe Zipper do
  it 'uses CUDA decode and encode when cuda is enabled' do
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
    expect(Sh).to have_received(:run).with(include('-c:v h264_nvenc'))
  end

  it 'caps computed video maxrate for very short videos' do
    begin
      Zipper.size_mb_limit = 2_000
      probe = SymMash.new(
        format:  SymMash.new(duration: 1),
        streams: [SymMash.new(codec_type: 'video', width: 128, height: 96)],
      )
      opts = SymMash.new(
        format:   Zipper::Types.video.h264,
        acodec:   'aac',
        metadata: {},
      )

      allow(Sh).to receive(:run)

      described_class.new('/tmp/in.mp4', '/tmp/out.mp4', probe: probe, opts: opts).zip_video

      expect(Sh).to have_received(:run).with(include('-maxrate:v 50000k'))
    ensure
      Zipper.size_mb_limit = nil
    end
  end

  it 'applies computed video size caps to CUDA encodes' do
    begin
      Zipper.size_mb_limit = 2_000
      probe = SymMash.new(
        format:  SymMash.new(duration: 3600),
        streams: [SymMash.new(codec_type: 'video', width: 1280, height: 720)],
      )
      opts = SymMash.new(
        cuda:     1,
        format:   Zipper::Types.video.h264,
        acodec:   'aac',
        metadata: {},
      )

      allow(Sh).to receive(:run)

      described_class.new('/tmp/in.mp4', '/tmp/out.mp4', probe: probe, opts: opts).zip_video

      expect(Sh).to have_received(:run).with(include('-rc:v vbr -maxrate:v 4336k -bufsize 1971M'))
    ensure
      Zipper.size_mb_limit = nil
    end
  end

  it 'uses CUDA decode without NVENC when cudadec is enabled alone' do
    probe = SymMash.new(
      format: SymMash.new(duration: 60),
      streams: [SymMash.new(codec_type: 'video', width: 1920, height: 1080)],
    )
    opts = SymMash.new(
      cudadec: 1,
      format: Zipper::Types.video.h264,
      acodec: 'aac',
      metadata: {},
    )

    allow(Sh).to receive(:run)

    described_class.new('/tmp/in.mp4', '/tmp/out.mp4', probe: probe, opts: opts).zip_video

    expect(Sh).to have_received(:run).with(include('-hwaccel cuda -i /tmp/in.mp4'))
    expect(Sh).to have_received(:run).with(include('-c:v libx264'))
  end

  it 'keeps NVENC but skips CUDA decode when cudaenc is enabled alone' do
    probe = SymMash.new(
      format: SymMash.new(duration: 60),
      streams: [SymMash.new(codec_type: 'video', width: 1920, height: 1080)],
    )
    opts = SymMash.new(
      cudaenc: 1,
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

  it 'applies voice quality filters only to audio encodes' do
    probe = SymMash.new(
      format: SymMash.new(duration: 60),
      streams: [SymMash.new(codec_type: 'audio')],
    )
    opts = SymMash.new(
      voice_quality: 1,
      format:        Zipper::Types.audio.mp3,
      metadata:      {},
    )

    allow(Sh).to receive(:run)

    described_class.new('/tmp/in.webm', '/tmp/out.mp3', probe: probe, opts: opts).zip_audio

    expect(Sh).to have_received(:run).with(include('-af highpass=f=80,lowpass=f=9000,afftdn=nf=-25'))
  end

  it 'creates pause wavs at the requested sample rate' do
    Dir.mktmpdir('pause-spec-') do |dir|
      allow(Sh).to receive(:run) do
        File.write(File.join(dir, 'pause_0_1_24000.wav'), 'wav')
        ['', '', double(success?: true)]
      end

      path = described_class.get_pause_file(0.1, dir, sample_rate: 24_000)

      expect(path).to end_with('pause_0_1_24000.wav')
      expect(Sh).to have_received(:run).with(include('sample_rate=24000'))
    end
  end

  it 'stream-copies audio concat when input streams match' do
    stream = SymMash.new(
      codec_type:      'audio',
      codec_name:      'pcm_s16le',
      sample_rate:     24_000,
      channels:        1,
      bits_per_sample: 16,
      sample_fmt:      's16',
    )
    allow(Prober).to receive(:for).and_return(SymMash.new(streams: [stream]))
    allow(Sh).to receive(:run).and_return(['', '', double(success?: true)])

    described_class.concat_audio(['/tmp/one.wav', '/tmp/two.wav'], '/tmp/out.wav')

    expect(Sh).to have_received(:run).with(include('-f concat', '-c copy'))
  end

  it 're-encodes audio concat when input streams differ' do
    allow(Prober).to receive(:for) do |path|
      rate = path.include?('pause') ? 22_050 : 24_000
      SymMash.new(streams: [SymMash.new(
        codec_type:      'audio',
        codec_name:      'pcm_s16le',
        sample_rate:     rate,
        channels:        1,
        bits_per_sample: 16,
        sample_fmt:      's16',
      )])
    end
    allow(Sh).to receive(:run).and_return(['', '', double(success?: true)])

    described_class.concat_audio(['/tmp/pause.wav', '/tmp/speech.wav'], '/tmp/out.wav')

    expect(Sh).to have_received(:run).with(
      include('-filter_complex "[0:a][1:a]concat=n=2:v=0:a=1,aresample=24000[a]"')
    )
  end

  it 'transcribes subtitles when gensubs is the only subtitle option' do
    dir = Dir.mktmpdir('zipper-gensubs-')
    probe = SymMash.new(
      format: SymMash.new(duration: 60),
      streams: [SymMash.new(codec_type: 'video', width: 1920, height: 1080)],
    )
    opts = SymMash.new(
      gensubs:  1,
      format:   Zipper::Types.video.h264,
      acodec:   'aac',
      metadata: {},
    )
    info = SymMash.new(title: 't')
    tsp = SymMash.new(
      segments: [
        SymMash.new(
          start: 0.0,
          end:   1.0,
          text:  'hello',
          words: [SymMash.new(start: 0.0, end: 1.0, word: ' hello')],
        ),
      ],
    )

    allow(Subtitler).to receive(:transcribe).and_return(SymMash.new(output: tsp, lang: 'en'))
    allow(Sh).to receive(:run)

    described_class.new('/tmp/in.mp4', File.join(dir, 'out.mp4'), info: info, probe: probe, opts: opts).zip_video

    expect(Subtitler).to have_received(:transcribe).with('/tmp/in.mp4')
    expect(Sh).to have_received(:run).with(include('ass='))
    expect(Sh).to have_received(:run).with(include('-i ', '.vtt'))
  ensure
    FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
  end
end
