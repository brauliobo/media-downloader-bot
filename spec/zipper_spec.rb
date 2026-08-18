require 'spec_helper'

RSpec.describe Zipper do
  def video_probe duration: 60, audio: false, width: 1920, height: 1080
    streams = [SymMash.new(codec_type: 'video', width: width, height: height)]
    streams << SymMash.new(codec_type: 'audio') if audio
    SymMash.new(format: SymMash.new(duration: duration), streams: streams)
  end

  def audio_probe duration: 60
    SymMash.new(format: SymMash.new(duration: duration), streams: [SymMash.new(codec_type: 'audio')])
  end

  def ffmpeg_double result: ['', '', nil]
    ffmpeg = instance_double FFmpeg
    methods = %i[
      input seek probe disable output_frame_rate output_sample_rate output_channels frame_rate_mode
      add_filter add_map map_stream scale preserve_resolution_scale metadata codec encode_video maxrate buffer_size
      rate_control bitrate no_audio copy_audio encode_audio metadata_policy movflags
      end_at duration output capture create_silence concat_audio add_audio_floor speed_audio
      audio_to_wav convert_subtitle subtitle_codec
    ]
    methods.each { |method| allow(ffmpeg).to receive(method) }
    allow(ffmpeg).to receive(:capture).and_return result
    ffmpeg
  end

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

  it 'cleans a temporary wav after yielding it through an injected builder' do
    ffmpeg = ffmpeg_double
    output = nil
    allow(ffmpeg).to receive(:audio_to_wav) do |arguments|
      output = arguments.fetch(:output)
      File.write output, 'wav'
      output
    end

    result = described_class.with_audio_wav '/tmp/input.mp4', sample_rate: 16_000, channels: 1,
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

  it 'delegates pause helpers to one semantic FFmpeg pause encoding' do
    format = {codec_name: 'aac', profile: 'HE-AAC', bit_rate: 32_004}
    encoding = FFmpeg::PauseEncoding.new(
      codec: 'libfdk_aac', profile: 'aac_he', bitrate: 32_004, sample_format: nil
    )
    allow(FFmpeg).to receive(:pause_encoding).with(format, fdk_aac: true).and_return(encoding)

    expect(described_class.pause_encoder(format, fdk_aac: true)).to eq 'libfdk_aac'
    expect(described_class.pause_profile(format, encoding.codec, fdk_aac: true)).to eq 'aac_he'
    expect(described_class.pause_bitrate(format, encoding.codec, fdk_aac: true)).to eq 32_004
    expect(described_class.pause_sample_format(format, encoding.codec, fdk_aac: true)).to be_nil
    expect(FFmpeg).to have_received(:pause_encoding).with(format, fdk_aac: true).exactly(4).times
  end

  it 'creates cached pauses through FFmpeg semantic silence construction' do
    Dir.mktmpdir('pause-spec-') do |dir|
      ffmpeg = ffmpeg_double
      allow(ffmpeg).to receive(:create_silence) do |arguments|
        File.write arguments.fetch(:output), 'silence'
        arguments.fetch(:output)
      end

      path = described_class.get_pause_file 0.1, dir, sample_rate: 24_000, ffmpeg: ffmpeg

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

      path = described_class.get_pause_file 3.5, dir, sample_rate: 24_000,
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

      path = described_class.get_pause_file 3.5, dir, format: format, extension: '.wav', ffmpeg: ffmpeg

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

      path = described_class.get_pause_file 3.5, dir, format: format, extension: '.m4a', ffmpeg: ffmpeg

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

      path = described_class.get_pause_file 3.5, dir, format: format, extension: '.m4a', ffmpeg: ffmpeg

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
      described_class.silence_file path, 3.5, format: format, ffmpeg: ffmpeg

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

  it 'uses the FFmpeg-owned voice quality filter' do
    ffmpeg = ffmpeg_double

    described_class.new(
      '/tmp/in.wav', '/tmp/out.opus', probe: audio_probe,
      opts: SymMash.new(format: Zipper::Types.audio.opus, voice_quality: true), ffmpeg: ffmpeg
    ).zip_audio

    expect(ffmpeg).to have_received(:add_filter).with(FFmpeg::VOICE_QUALITY_FILTER, stream: :audio)
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
          described_class.get_pause_file 0.1, dir, sample_rate: 24_000, ffmpeg: ffmpeg
        end
      end

      expect(threads.map(&:value).uniq).to contain_exactly File.join(dir, 'pause_0_1_24000.wav')
      expect(runs).to eq 1
      expect(ffmpeg).to have_received(:create_silence).once
    end
  end

  it 'preserves single-input copy compatibility and uses semantic concat for multiple inputs' do
    Dir.mktmpdir('concat-spec-') do |dir|
      one = File.join dir, 'one.wav'
      output = File.join dir, 'out.wav'
      File.write one, 'one'
      expect(described_class.concat_audio([one], output)).to be_nil
      expect(File.read(output)).to eq 'one'

      ffmpeg = ffmpeg_double
      signature = {codec_name: 'pcm_s16le', sample_rate: 24_000, channels: 1}
      allow(Prober).to receive(:audio_signature).and_return signature
      described_class.concat_audio %w[first.wav second.wav], '/tmp/out.wav', ffmpeg: ffmpeg

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

    described_class.concat_audio %w[/tmp/pause.wav /tmp/speech.wav], '/tmp/out.wav', ffmpeg: ffmpeg

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
      described_class.concat_audio %w[first.wav second.wav], '/tmp/out.wav', ffmpeg: ffmpeg
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

      expect(described_class.add_audio_floor!(
        source, amplitude: 0.001, loudness_lufs: -18, sample_rate: 24_000, ffmpeg: ffmpeg
      )).to eq source
      expect(File.read(source)).to eq 'speech with floor'
      expect(ffmpeg).to have_received(:add_audio_floor).with(
        input: source, amplitude: 0.001, loudness_lufs: -18,
        output: match(%r{/audio_floor_.*\.wav\z}),
        sample_rate: 24_000, label: 'Failed to add audiobook audio floor'
      )

      expect(described_class.speed_audio_file!(source, 1.2, ffmpeg: ffmpeg)).to eq source
      expect(File.read(source)).to eq 'sped'
      expect(ffmpeg).to have_received(:speed_audio).with(
        input: source, output: match(%r{/speed_.*\.wav\z}),
        filter: match(/rubberband=tempo=1\.2.*formant=preserved/),
        label: 'Failed to apply audio speed'
      )
    end
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

  it 'preserves the WAV conversion error label' do
    ffmpeg = ffmpeg_double
    allow(ffmpeg).to receive(:audio_to_wav).and_raise Sh::Error.new('ffmpeg failed', 'invalid audio')

    expect {
      described_class.audio_to_wav '/tmp/input.mp4', ffmpeg: ffmpeg
    }.to raise_error 'ffmpeg failed'
  end
end
