require 'rails_helper'

RSpec.describe Zipper do
  def video_probe duration: 60, audio: false, width: 1920, height: 1080
    streams = [SymMash.new(codec_type: 'video', width: width, height: height)]
    streams << SymMash.new(codec_type: 'audio') if audio
    SymMash.new(format: SymMash.new(duration: duration), streams: streams)
  end

  def audio_probe duration: 60
    SymMash.new(format: SymMash.new(duration: duration), streams: [SymMash.new(codec_type: 'audio')])
  end

  include FFmpegDouble

  def video_options(extra = {})
    SymMash.new({format: Zipper::Types.video.h264, metadata: {}}.merge(extra))
  end

  it 'preserves the historical input and output option readers' do
    zipper = described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe, opts: video_options
    )

    expect(zipper.iopts).to eq ''
    expect(zipper.oopts).to eq ''
  end

  it 'returns raw FFmpeg capture tuples and expresses CUDA decisions semantically' do
    ffmpeg = ffmpeg_double result: ['stdout', 'stderr', :status]
    opts = video_options cuda: true, acodec: 'aac'

    result = described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe, opts: opts, ffmpeg: ffmpeg
    ).zip_video

    expect(result).to eq ['stdout', 'stderr', :status]
    expect(ffmpeg).to have_received(:input).with '/tmp/in.mp4', cuda: true
    expect(ffmpeg).to have_received(:encode_video).with :h264, cuda: true, quality: 33
    expect(ffmpeg).to have_received(:capture)
  end

  it 'uses named variable-frame-rate and quality operations' do
    ffmpeg = ffmpeg_double
    zipper = described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe, opts: video_options(maxfr: 24, quality: 28),
      ffmpeg: ffmpeg
    )

    zipper.zip_video

    expect(ffmpeg).to have_received(:output_frame_rate).with 24
    expect(ffmpeg).to have_received(:frame_rate_mode).with :vfr
    expect(ffmpeg).to have_received(:encode_video).with :h264, cuda: false, quality: 28
  end

  it 'copies dubbed audio until a semantic audio change requires re-encoding' do
    copy_ffmpeg = ffmpeg_double
    described_class.new(
      '/tmp/dubbed.mp4', '/tmp/out.mp4', probe: video_probe, opts: video_options(dub: true),
      ffmpeg: copy_ffmpeg
    ).zip_video

    expect(copy_ffmpeg).to have_received(:copy_audio)
    expect(copy_ffmpeg).not_to have_received(:encode_audio)

    filtered_ffmpeg = ffmpeg_double
    described_class.new(
      '/tmp/dubbed.mp4', '/tmp/out.mp4', probe: video_probe, opts: video_options(dub: true, speed: 1.2),
      ffmpeg: filtered_ffmpeg
    ).zip_video

    expect(filtered_ffmpeg).to have_received(:add_filter).with 'atempo=1.2', stream: :audio
    expect(filtered_ffmpeg).to have_received(:encode_audio).with :aac, bitrate: 64
    expect(filtered_ffmpeg).not_to have_received(:copy_audio)
  end

  it 'falls back to Opus for unknown requested audio codecs' do
    ffmpeg = ffmpeg_double

    described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe(audio: true),
      opts: video_options(acodec: 'unknown'), ffmpeg: ffmpeg
    ).zip_video

    expect(ffmpeg).to have_received(:encode_audio).with :opus, bitrate: 64
  end

  it 'uses named audio rate and channel operations when re-encoding' do
    ffmpeg = ffmpeg_double
    opts = video_options(dub: true, freq: 44_100, ac: 2)

    described_class.new(
      '/tmp/dubbed.mp4', '/tmp/out.mp4', probe: video_probe, opts: opts, ffmpeg: ffmpeg
    ).zip_video

    expect(ffmpeg).to have_received(:output_sample_rate).with 44_100
    expect(ffmpeg).to have_received(:output_channels).with 2
    expect(ffmpeg).not_to have_received(:copy_audio)
  end

  it 'applies exact semantic video size limits for a short video' do
    Zipper.size_mb_limit = 2_000
    ffmpeg = ffmpeg_double

    described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe(duration: 1, width: 128, height: 96),
      opts: video_options, ffmpeg: ffmpeg
    ).zip_video

    expect(ffmpeg).to have_received(:maxrate).with '50000k', stream: :video
    expect(ffmpeg).to have_received(:buffer_size).with '1999M'
  ensure
    Zipper.size_mb_limit = nil
  end

  it 'applies CUDA rate control, maxrate, and buffer size limits' do
    Zipper.size_mb_limit = 2_000
    ffmpeg = ffmpeg_double

    described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe(duration: 3_600, audio: true),
      opts: video_options(cuda: true), ffmpeg: ffmpeg
    ).zip_video

    expect(ffmpeg).to have_received(:rate_control).with :vbr, stream: :video
    expect(ffmpeg).to have_received(:maxrate).with '4336k', stream: :video
    expect(ffmpeg).to have_received(:buffer_size).with '1971M'
  ensure
    Zipper.size_mb_limit = nil
  end

  it 'does not apply video size limits to an infinite-duration source' do
    Zipper.size_mb_limit = 2_000
    ffmpeg = ffmpeg_double

    described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe(duration: Float::INFINITY),
      opts: video_options, ffmpeg: ffmpeg
    ).zip_video

    expect(ffmpeg).not_to have_received(:maxrate)
  ensure
    Zipper.size_mb_limit = nil
  end

  it 'keeps validated video, audio, cut, silence, and speed filters in semantic state' do
    ffmpeg = ffmpeg_double
    opts = video_options(
      cuts: '10-20', silences: '30-40', speed: 1.2,
      vf: 'mpdecimate=hi=1024:lo=512:frac=0.40'
    )

    described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe(audio: true), opts: opts, ffmpeg: ffmpeg
    ).zip_video

    expect(ffmpeg).to have_received(:add_filter).with(
      'mpdecimate=hi=1024:lo=512:frac=0.40', stream: :video
    )
    expect(ffmpeg).to have_received(:add_filter).with 'setpts=PTS/1.2', stream: :video
    expect(ffmpeg).to have_received(:add_filter).with 'atempo=1.2', stream: :audio
    expect(ffmpeg).to have_received(:add_filter).with(
      "volume=0:enable='between(t\\,30\\,40)'", stream: :audio
    )
    expect(ffmpeg).to have_received(:add_filter).with(
      "select='not(between(t\\,10\\,20))'", stream: :video
    )
  end

  it 'applies ss and to as numeric ffmpeg seek bounds' do
    ffmpeg = ffmpeg_double
    opts = video_options(ss: '1m30s', to: '2:00')

    described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe, opts: opts, ffmpeg: ffmpeg
    ).zip_video

    expect(ffmpeg).to have_received(:seek).with(90.0)
    expect(ffmpeg).to have_received(:end_at).with(120.0)
    expect(ffmpeg).not_to have_received(:duration)
  end

  it 'applies t as an ffmpeg duration after ss' do
    ffmpeg = ffmpeg_double
    opts = video_options(ss: '1:', t: '30s')

    described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe, opts: opts, ffmpeg: ffmpeg
    ).zip_video

    expect(ffmpeg).to have_received(:seek).with(60.0)
    expect(ffmpeg).to have_received(:duration).with(30.0)
    expect(ffmpeg).not_to have_received(:end_at)
  end

  it 'rejects combining t with to' do
    expect do
      described_class.new(
        '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe, opts: video_options(to: '2m', t: '30s')
      ).zip_video
    end.to raise_error(ArgumentError, /cannot combine with to/)
  end

  it 'delegates semantic filter construction to FFmpeg' do
    ffmpeg = ffmpeg_double
    zipper = described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe, opts: video_options(width: 720), ffmpeg: ffmpeg
    )
    expect(FFmpeg).to receive(:scale_filter).with(width: 720, modulus: 2).and_call_original
    zipper.send(:scale_filters)
  end

  it 'delegates metadata policy and subtitle state without raw options' do
    ffmpeg = ffmpeg_double
    zipper = described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe, opts: video_options(metadata: {title: 'Title'}),
      ffmpeg: ffmpeg
    )
    expect(FFmpeg).to receive(:subtitle_ass_filter).with('/tmp/a:b,c.ass').and_call_original
    allow(Zipper::Subtitle).to receive(:apply) do |instance|
      instance.burn_subtitle '/tmp/a:b,c.ass'
      instance.add_subtitle_input '/tmp/subtitle.vtt', language: 'en'
    end

    zipper.zip_video

    expect(ffmpeg).to have_received(:input).with '/tmp/subtitle.vtt'
    expect(ffmpeg).to have_received(:add_filter).with(
      'ass=/tmp/a\\:b\\,c.ass', stream: :video
    )
    expect(ffmpeg).to have_received(:map_stream).with :subtitle, input: 1
    expect(ffmpeg).to have_received(:subtitle_codec)
    expect(ffmpeg).to have_received(:metadata).with :language, 'en', stream: :subtitle
    expect(ffmpeg).to have_received(:metadata_policy).with tags: {title: 'Title'}, mark: true
    expect(ffmpeg).to have_received(:movflags).with '+faststart'
  end

  it 'keeps FFmpeg automatic stream selection for ordinary video inputs' do
    ffmpeg = ffmpeg_double

    described_class.new(
      '/tmp/in.mp4', '/tmp/out.mp4', probe: video_probe(audio: true),
      opts: video_options, ffmpeg: ffmpeg
    ).zip_video

    expect(ffmpeg).not_to have_received(:map_stream)
  end

  it 'uses the FFmpeg-owned voice quality filter' do
    ffmpeg = ffmpeg_double

    described_class.new(
      '/tmp/in.wav', '/tmp/out.opus', probe: audio_probe,
      opts: SymMash.new(format: Zipper::Types.audio.opus, voice_quality: true), ffmpeg: ffmpeg
    ).zip_audio

    expect(ffmpeg).to have_received(:add_filter).with(FFmpeg::VOICE_QUALITY_FILTER, stream: :audio)
  end

  it 'extracts and sanitizes a selected subtitle stream through FFmpeg' do
    ffmpeg = ffmpeg_double
    probe = SymMash.new(
      format: SymMash.new(duration: 60),
      streams: [
        SymMash.new(codec_type: 'subtitle', tags: SymMash.new(language: 'en')),
        SymMash.new(codec_type: 'subtitle', tags: SymMash.new(language: 'pt')),
      ]
    )
    allow(ffmpeg).to receive(:convert_subtitle).and_return "WEBVTT\n\nHello\\Nworld"

    allow(ffmpeg).to receive(:probe).and_return probe
    result = described_class.extract_vtt '/tmp/video.mkv', 'pt', ffmpeg: ffmpeg

    expect(result).to eq "WEBVTT\n\nHello\nworld"
    expect(ffmpeg).to have_received(:convert_subtitle).with(
      input: '/tmp/video.mkv', format: :vtt, stream_index: 1, label: 'VTT extraction failed'
    )
  end
end
