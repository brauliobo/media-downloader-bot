require 'spec_helper'
require 'tmpdir'
require_relative '../lib/ffmpeg'

RSpec.describe FFmpeg do
  def status success
    instance_double Process::Status, success?: success
  end

  describe '.verify!' do
    it 'preserves the class runner API and verifies both binaries' do
      commands = []
      runner = lambda do |command|
        commands << command
        ["#{File.basename command.first} version n9.0 Copyright FFmpeg", '', status(true)]
      end

      expect { described_class.verify! runner: runner }.not_to raise_error
      expect(commands).to eq [
        %w[ffmpeg -version],
        %w[ffprobe -version]
      ]
    end

    it 'rejects an older version' do
      runner = lambda do |command|
        ["#{File.basename command.first} version 8.1 Copyright FFmpeg", '', status(true)]
      end

      expect { described_class.verify! runner: runner }
        .to raise_error RuntimeError, 'ffmpeg 9.0 or newer is required; found 8.1'
    end

    it 'rejects a missing binary' do
      runner = ->(*) { raise Errno::ENOENT }

      expect { described_class.verify! runner: runner }
        .to raise_error RuntimeError, 'ffmpeg is required'
    end

    it 'rejects an unparseable version' do
      runner = ->(*) { ['unexpected output', '', status(true)] }

      expect { described_class.verify! runner: runner }
        .to raise_error RuntimeError, 'unable to determine ffmpeg version'
    end
  end

  describe '.pause_encoding' do
    it 'returns immutable encoding options for mapped codecs' do
      expect(described_class.pause_encoding({codec_name: 'mp3', bit_rate: 128_000})).to eq(
        described_class::PauseEncoding.new(
          codec: 'libmp3lame', profile: nil, bitrate: 128_000, sample_format: nil
        )
      )
      expect(described_class.pause_encoding({codec_name: 'opus', bit_rate: 96_000})).to eq(
        described_class::PauseEncoding.new(
          codec: 'libopus', profile: nil, bitrate: 96_000, sample_format: nil
        )
      )
      expect(described_class.pause_encoding({codec_name: 'vorbis', bit_rate: 64_000})).to eq(
        described_class::PauseEncoding.new(
          codec: 'libvorbis', profile: nil, bitrate: 64_000, sample_format: nil
        )
      )
      expect(described_class.pause_encoding({codec_name: 'pcm_s16le', bit_rate: 128_000,
                                             sample_fmt: 's16'})).to eq(
        described_class::PauseEncoding.new(
          codec: 'pcm_s16le', profile: nil, bitrate: nil, sample_format: 's16'
        )
      )
      expect(described_class.pause_encoding({codec_name: 'flac', bit_rate: 128_000})).to eq(
        described_class::PauseEncoding.new(
          codec: 'flac', profile: nil, bitrate: nil, sample_format: nil
        )
      )
      expect(described_class.pause_encoding({codec_name: 'pcm_s16le', sample_fmt: :s16})).to be_frozen
    end

    it 'selects AAC FDK and maps AAC profiles without implicit capability checks' do
      expect(described_class).not_to receive(:fdk_aac_available?)

      expect(described_class.pause_encoding(
        {codec_name: 'aac', profile: 'LC', bit_rate: 32_000}, fdk_aac: false
      )).to eq described_class::PauseEncoding.new(
        codec: 'aac', profile: 'aac_low', bitrate: 32_000, sample_format: nil
      )
      expect(described_class.pause_encoding(
        {codec_name: 'aac', profile: 'HE-AACV2', bit_rate: 32_000}, fdk_aac: true
      )).to eq described_class::PauseEncoding.new(
        codec: 'libfdk_aac', profile: 'aac_he_v2', bitrate: 32_000, sample_format: nil
      )
    end

    it 'refuses HE-AAC profiles when FDK is unavailable' do
      expect(described_class.pause_encoding(
        {codec_name: 'aac', profile: 'HE-AAC', bit_rate: 32_000}, fdk_aac: false
      )).to eq described_class::PauseEncoding.new(
        codec: nil, profile: nil, bitrate: nil, sample_format: nil
      )
    end

    it 'checks FDK availability only when capability is unspecified' do
      allow(described_class).to receive(:fdk_aac_available?).and_return true

      expect(described_class.pause_encoding(
        {codec_name: 'aac', profile: 'HE-AAC', bit_rate: 32_000}
      )).to eq described_class::PauseEncoding.new(
        codec: 'libfdk_aac', profile: 'aac_he', bitrate: 32_000, sample_format: nil
      )
      expect(described_class).to have_received(:fdk_aac_available?).once
    end
  end

  describe 'FFmpeg media constants and binary selection' do
    it 'owns frozen audio analysis labels' do
      expect(described_class::TOOLS).to eq(
        signal:       'ffmpeg astats',
        frame_signal: 'ffmpeg astats metadata',
        loudness:     'ffmpeg ebur128',
        silence:      'ffmpeg silencedetect'
      )
      expect(described_class::TOOLS).to be_frozen
    end

    it 'owns frozen media filter and subtitle codec values' do
      expect(described_class::VOICE_QUALITY_FILTER).to eq(
        'highpass=f=80,lowpass=f=9000,afftdn=nf=-25,' \
        'acompressor=threshold=-18dB:ratio=2.5:attack=20:release=250,' \
        'dynaudnorm=f=150:g=15,loudnorm=I=-16:TP=-1.5:LRA=11,volume=-2.5dB'
      )
      expect(described_class::SPEECH_CLEANUP_FILTER).to eq 'highpass=f=80'
      expect(described_class::SUBTITLE_CODEC).to eq 'mov_text'
      expect(described_class::VOICE_QUALITY_FILTER).to be_frozen
      expect(described_class::SPEECH_CLEANUP_FILTER).to be_frozen
      expect(described_class::SUBTITLE_CODEC).to be_frozen
    end

    it 'uses the configured transcription FFmpeg override' do
      original = ENV['TRANSCRIBE_CPP_FFMPEG']
      ENV['TRANSCRIBE_CPP_FFMPEG'] = '/opt/transcribe/ffmpeg'

      expect(described_class.transcription_binary).to eq '/opt/transcribe/ffmpeg'
    ensure
      original ? ENV['TRANSCRIBE_CPP_FFMPEG'] = original : ENV.delete('TRANSCRIBE_CPP_FFMPEG')
    end

    it 'defaults the transcription binary to the first configured binary' do
      original = ENV.delete('TRANSCRIBE_CPP_FFMPEG')

      expect(described_class.transcription_binary).to eq described_class::BINARIES.first
    ensure
      ENV['TRANSCRIBE_CPP_FFMPEG'] = original if original
    end
  end

  describe 'filter constructors' do
    let(:intervals) do
      [
        instance_double('interval', start: 10, finish: 20),
        instance_double('interval', start: 30, finish: 40),
      ]
    end
    let(:ranges) { instance_double('ranges', intervals: intervals) }

    it 'builds semantic scale, speed, interval, and audio filters' do
      expression = 'between(t\\,10\\,20)+between(t\\,30\\,40)'

      expect(described_class.scale_filter(width: 720, modulus: 8))
        .to eq 'scale=720:trunc(ow/a/8)*8'
      expect(described_class.format_filter(:yuv420p)).to eq 'format=yuv420p'
      expect(described_class.preserve_resolution_scale_filter(modulus: 8))
        .to eq 'scale=trunc(iw/8)*8:trunc(ih/8)*8'
      expect(described_class.decimate_filter).to eq 'mpdecimate'
      expect(described_class.decimate_filter('hi=1024:lo=512:frac=0.40'))
        .to eq 'mpdecimate=hi=1024:lo=512:frac=0.40'
      expect(described_class.speed_filter(1.25, stream: :video)).to eq 'setpts=PTS/1.25'
      expect(described_class.speed_filter(1.25, stream: :audio)).to eq 'atempo=1.25'
      expect(described_class.time_ranges_expression(ranges)).to eq expression
      expect(described_class.cut_filters(ranges, video: true, audio: true)).to eq(
        video: ["select='not(#{expression})'", 'setpts=N/FRAME_RATE/TB'],
        audio: ["aselect='not(#{expression})'", 'asetpts=N/SR/TB']
      )
      expect(described_class.silence_filter(ranges)).to eq "volume=0:enable='#{expression}'"
    end

    it 'builds semantic speech, subtitle, dubbing, floor, and reference filters' do
      expect(described_class.silence_source(sample_rate: 48_000, channel_layout: :mono))
        .to eq 'anullsrc=channel_layout=mono:sample_rate=48000'
      expect(described_class.noise_source(amplitude: 0.001, sample_rate: 24_000))
        .to eq 'anoisesrc=color=white:amplitude=0.001:sample_rate=24000'
      expect(described_class.audio_floor_source(amplitude: 0.001, sample_rate: 24_000))
        .to eq 'anoisesrc=color=white:amplitude=0.001:sample_rate=24000'
      expect(described_class.voice_quality_filter).to eq described_class::VOICE_QUALITY_FILTER
      expect(described_class.speech_cleanup_filter).to eq 'highpass=f=80'
      expect(described_class.speech_speed_filter(1.2)).to eq(
        'rubberband=tempo=1.2:pitch=1:transients=smooth:detector=soft:' \
        'phase=laminar:window=long:formant=preserved'
      )
      expect(described_class.subtitle_ass_filter('/tmp/a:b,c.ass'))
        .to eq 'ass=/tmp/a\\:b\\,c.ass'
      expect(described_class.dub_audio_mix_filter(duration: 6.0)).to include(
        'amix=inputs=2:normalize=0', 'atrim=0:6.0'
      )
      expect(described_class.audio_floor_filter(loudness_lufs: -18)).to include(
        'loudnorm=I=-18:TP=-2:LRA=11', 'alimiter=limit=0.841395'
      )
      expect(described_class.atempo_chain(4.8))
        .to eq 'atempo=2.000000,atempo=2.000000,atempo=1.200000'
      expect(described_class.voice_reference_filter(
        :clone, silence_threshold_db: -35, pad_duration: 0.15
      )).to eq 'highpass=f=80,afftdn=nf=-25,loudnorm=I=-16:TP=-1.5:LRA=11,apad=pad_dur=0.15'
    end

    it 'rejects unsafe decimate settings' do
      expect { described_class.decimate_filter('hi=1;touch=/tmp/pwn') }
        .to raise_error ArgumentError, /unsafe video filter/
    end
  end

  describe 'builder' do
    it 'has no memoized default or Utils compatibility alias' do
      expect(described_class).not_to respond_to :default
      expect(Utils.const_defined?(:FFmpeg, false)).to be false
    end

    it 'injects binaries, runner, threads, and profile' do
      runner = instance_double Proc
      result = ['', '', status(true)]
      allow(runner).to receive(:call).and_return result
      ffmpeg = described_class.new(
        ffmpeg: '/opt/bin/ffmpeg',
        ffprobe: '/opt/bin/ffprobe',
        runner: runner,
        threads: 3,
        profile: :analysis
      )

      expect(ffmpeg.input('voice.wav').format(:null).output(:stdout).capture).to equal result
      expect(runner).to have_received(:call).with [
        '/opt/bin/ffmpeg', '-hide_banner', '-nostats',
        '-i', 'voice.wav', '-f', 'null', '-'
      ]
    end

    it 'returns self from every option in a representative video chain' do
      runner = instance_double Proc
      allow(runner).to receive(:call).and_return ['', '', status(true)]
      ffmpeg = described_class.new runner: runner, threads: 4

      result = ffmpeg.overwrite
                     .threads(2)
                     .loglevel(:warning)
                     .hide_banner
                     .no_stats
                     .cuda(decode: true, encode: true)
                     .input('video.mp4', keyframes_only: true)
                     .seek(1.5)
                     .duration(10)
                     .end_at(20)
                     .scale(width: 720, modulus: 8)
                     .add_filter('format=yuv420p', stream: :video)
                     .set_complex_filter('[0:v]null[v]')
                     .add_map('0:a?')
                     .map_stream(:video)
                     .map_filter(:v)
                     .codec('hevc_nvenc', stream: :video)
                     .copy(stream: :audio)
                     .frame_rate(30, stream: :video)
                     .frame_rate_mode(:vfr)
                     .quality(25)
                     .preset(:p5)
                     .tune(:hq)
                     .multipass(:qres)
                     .adaptive_quantization
                     .lookahead(32)
                     .maxrate('900k', stream: :video)
                     .buffer_size('18M')
                     .rate_control(:vbr, stream: :video)
                     .movflags('+faststart')
                     .output(:stdout)

      expect(result).to equal ffmpeg
    end

    it 'builds exact argv for a representative CUDA video command' do
      runner = instance_double Proc
      allow(runner).to receive(:call).and_return ['video', '', status(true)]
      ffmpeg = described_class.new ffmpeg: '/usr/bin/ffmpeg', runner: runner, threads: 4

      result = ffmpeg.cuda(decode: true, encode: true)
                     .input('input.mp4', keyframes_only: true)
                     .scale(width: 720)
                     .add_filter('format=yuv420p', stream: :video)
                     .frame_rate_mode(:vfr)
                     .map_stream(:video)
                     .codec('h264_nvenc', stream: :video)
                     .quality(33)
                     .preset(:p4)
                     .tune(:hq)
                     .adaptive_quantization
                     .bitrate(0, stream: :video, unit: :bit)
                     .rate_control(:vbr, stream: :video)
                     .maxrate('850k', stream: :video)
                     .buffer_size('20M')
                     .movflags('+faststart')
                     .output(:stdout)
                     .run! label: 'video encode failed'

      expect(result).to eq 'video'
      expect(runner).to have_received(:call).with [
        '/usr/bin/ffmpeg', '-y', '-threads', '4', '-loglevel', 'error',
        '-hwaccel', 'cuda', '-skip_frame', 'nokey', '-i', 'input.mp4',
        '-vf', 'scale=720:trunc(ow/a/2)*2,format=yuv420p', '-fps_mode', 'vfr',
        '-map', '0:v:0', '-c:v', 'h264_nvenc', '-cq', '33', '-preset', 'p4',
        '-tune', 'hq', '-spatial-aq', '1', '-temporal-aq', '1', '-b:v', '0',
        '-rc:v', 'vbr', '-maxrate:v', '850k', '-bufsize', '20M',
        '-movflags', '+faststart', '-'
      ]
    end

    it 'owns the exact CPU video encoder profiles' do
      expect(described_class::VIDEO_ENCODERS[:h264].values_at(
        :width, :quality, :audio_format, :audio_bitrate, :percent
      )).to eq [720, 25, :aac, 64, 0.99]
      expect(described_class::VIDEO_ENCODERS[:av1].values_at(
        :width, :quality, :audio_format, :audio_bitrate, :percent
      )).to eq [720, 50, :opus, 64, 0.99]
      expect(described_class::VIDEO_ENCODERS[:vp9].values_at(
        :width, :video_bitrate, :audio_format, :audio_bitrate, :percent
      )).to eq [720, 835, :aac, 64, 0.97]

      commands = []
      runner = lambda do |command|
        commands << command
        ['', '', status(true)]
      end
      ffmpeg = described_class.new runner: runner, profile: :plain

      ffmpeg.input('h264.mp4').encode_video(:h264, cuda: false, quality: 25).output(:stdout).capture
      ffmpeg.input('h265.mp4').encode_video(:h265, cuda: false, quality: 26).output(:stdout).capture
      ffmpeg.input('av1.mp4').encode_video(:av1, cuda: false, quality: 50).output(:stdout).capture
      ffmpeg.input('vp9.mp4').encode_video(:vp9, cuda: false, quality: 40).output(:stdout).capture

      expect(commands).to eq [
        %w[ffmpeg -i h264.mp4 -c:v libx264 -crf 25 -preset fast -],
        %w[ffmpeg -i h265.mp4 -c:v libx265 -crf 26 -preset fast -],
         %w[ffmpeg -i av1.mp4 -c:v libaom-av1 -crf 50 -],
         %w[ffmpeg -i vp9.mp4 -c:v libvpx-vp9 -]
      ]
    end

    it 'owns the exact CUDA video encoder profiles and accepts a preset override' do
      commands = []
      runner = lambda do |command|
        commands << command
        ['', '', status(true)]
      end
      ffmpeg = described_class.new runner: runner, profile: :plain

      ffmpeg.input('h264.mp4').encode_video(:h264, cuda: true, quality: 33).output(:stdout).capture
      ffmpeg.input('h265.mp4').encode_video(:h265, cuda: true, quality: 34).output(:stdout).capture
      ffmpeg.input('av1.mp4').encode_video(:av1, cuda: true, quality: 51, preset: :p7)
            .output(:stdout).capture
      ffmpeg.input('vp9.mp4').encode_video(:vp9, cuda: true, quality: 40).output(:stdout).capture

      expect(commands).to eq [
        %w[ffmpeg -i h264.mp4 -c:v h264_nvenc -cq 33 -preset p4 -tune hq
           -spatial-aq 1 -temporal-aq 1 -b:v 0 -],
        %w[ffmpeg -i h265.mp4 -c:v hevc_nvenc -cq 34 -preset p5 -tune hq
           -multipass qres -spatial-aq 1 -temporal-aq 1 -rc-lookahead 32 -b:v 0 -],
        %w[ffmpeg -i av1.mp4 -c:v av1_nvenc -cq 51 -preset p7 -],
         %w[ffmpeg -i vp9.mp4 -c:v libvpx-vp9 -]
      ]
    end

    it 'owns audio defaults, sizing coefficients, and exact encoder options' do
      expect(described_class::AUDIO_ENCODERS.transform_values { |profile| profile[:percent] })
        .to eq opus: 0.95, aac: 0.98, mp3: 0.99
      expect(described_class::AUDIO_ENCODERS.transform_values { |profile| profile[:bitrate] })
        .to eq opus: 96, aac: 96, mp3: 128

      commands = []
      runner = lambda do |command|
        commands << command
        ['', '', status(true)]
      end
      ffmpeg = described_class.new runner: runner, profile: :plain

      ffmpeg.input('voice.wav').encode_audio(:opus, bitrate: 64).output(:stdout).capture
      ffmpeg.input('voice.wav').encode_audio(:aac, bitrate: 80).output(:stdout).capture
      ffmpeg.input('voice.wav').encode_audio(:mp3, bitrate: 128).output(:stdout).capture

      expect(commands).to eq [
        %w[ffmpeg -i voice.wav -ac 1 -ar 48000 -c:a libopus -b:a 64k -],
        %w[ffmpeg -i voice.wav -c:a aac -b:a 80k -],
        %w[ffmpeg -i voice.wav -c:a libmp3lame -abr 1 -b:a 128k -]
      ]
    end

    it 'selects FDK AAC from constructor capability without encoder detection during a build' do
      commands = []
      runner = lambda do |command|
        commands << command
        ['', '', status(true)]
      end
      ffmpeg = described_class.new runner: runner, profile: :plain, fdk_aac: true

      ffmpeg.input('voice.wav').encode_audio(:aac, bitrate: 48).output(:stdout).capture

      expect(commands).to eq [[
        'ffmpeg', '-i', 'voice.wav', '-c:a', 'libfdk_aac', '-profile:a', 'aac_he',
        '-b:a', '48k', '-'
      ]]
      expect(commands).not_to include %w[ffmpeg -encoders]
    end

    it 'caches explicit FDK capability checks by binary and runner' do
      commands = []
      runner = lambda do |command|
        commands << command
        [" A..... libfdk_aac Fraunhofer encoder\n", '', status(true)]
      end

      expect(described_class.fdk_aac_available?(ffmpeg: '/opt/ffmpeg', runner: runner)).to be true
      expect(described_class.fdk_aac_available?(ffmpeg: '/opt/ffmpeg', runner: runner)).to be true
      expect(commands).to eq [%w[/opt/ffmpeg -encoders]]
    end

    it 'builds exact argv for a representative audio command' do
      runner = instance_double Proc
      allow(runner).to receive(:call).and_return ['audio', '', status(true)]
      ffmpeg = described_class.new runner: runner, threads: 2

      ffmpeg.disable(:video)
            .input('input.wav', format: :wav, sample_rate: 44_100, channels: 2,
                                channel_layout: :stereo)
            .add_filter('highpass=f=80', stream: :audio)
            .add_filter('loudnorm=I=-16', stream: :audio)
            .channels(1)
            .channel_layout(:mono)
            .sample_rate(48_000)
            .sample_format(:s16)
            .codec('libfdk_aac', stream: :audio)
            .codec_profile('aac_he', stream: :audio)
            .bitrate(96, stream: :audio)
            .metadata_from(0)
            .id3
            .metadata(:artist, 'Artist')
            .metadata(:album, 'Album')
            .format(:mp4)
            .output(:stdout)
            .capture

      expect(runner).to have_received(:call).with [
        'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error',
        '-vn', '-f', 'wav', '-ar', '44100', '-ac', '2', '-channel_layout', 'stereo',
        '-i', 'input.wav', '-af', 'highpass=f=80,loudnorm=I=-16',
        '-ac', '1', '-channel_layout', 'mono', '-ar', '48000', '-sample_fmt', 's16',
        '-c:a', 'libfdk_aac', '-profile:a', 'aac_he', '-b:a', '96k',
        '-map_metadata', '0', '-id3v2_version', '3', '-write_id3v1', '1',
        '-metadata', 'artist=Artist', '-metadata', 'album=Album', '-f', 'mp4', '-'
      ]
    end

    it 'builds exact argv for the configured subtitle codec and indexed metadata' do
      runner = instance_double Proc
      allow(runner).to receive(:call).and_return ['', '', status(true)]
      ffmpeg = described_class.new runner: runner, profile: :plain

      ffmpeg.input('input.mp4')
            .subtitle_codec
            .metadata(:language, :eng, stream: :subtitle, index: 0)
            .output(:stdout)
            .capture

      expect(runner).to have_received(:call).with [
        'ffmpeg', '-i', 'input.mp4', '-c:s', 'mov_text',
        '-metadata:s:0', 'language=eng', '-'
      ]
    end

    it 'supports structured concat input and per-input decode options' do
      runner = instance_double Proc
      allow(runner).to receive(:call).and_return ['', '', status(true)]
      ffmpeg = described_class.new runner: runner, profile: :plain

      ffmpeg.input('concat.txt', format: :concat, safe: false, seek: 2, duration: 4,
                                 cuda: true, keyframes_only: true)
            .copy
            .output(:stdout)
            .capture

      expect(runner).to have_received(:call).with [
        'ffmpeg', '-hwaccel', 'cuda', '-skip_frame', 'nokey', '-f', 'concat',
        '-safe', '0', '-ss', '2', '-t', '4', '-i', 'concat.txt', '-c', 'copy', '-'
      ]
    end

    it 'replaces a filter chain and clears filters by stream or globally' do
      commands = []
      runner = lambda do |command|
        commands << command
        ['', '', status(true)]
      end
      ffmpeg = described_class.new runner: runner, profile: :plain

      ffmpeg.input('first.mp4')
            .add_filter('old', stream: :video)
            .add_filter('loudnorm', stream: :audio)
            .set_filter('scale=640:-2', stream: :video)
            .clear_filters(:audio)
            .output(:stdout)
            .capture
      ffmpeg.input('second.mp4')
            .add_filter('scale=320:-2', stream: :video)
            .clear_filters
            .output(:stdout)
            .capture

      expect(commands).to eq [
        ['ffmpeg', '-i', 'first.mp4', '-vf', 'scale=640:-2', '-'],
        ['ffmpeg', '-i', 'second.mp4', '-']
      ]
    end

    it 'replaces complex filters while maps and metadata accumulate' do
      runner = instance_double Proc
      allow(runner).to receive(:call).and_return ['', '', status(true)]
      ffmpeg = described_class.new runner: runner, profile: :plain

      ffmpeg.input('input.mp4')
            .set_complex_filter('[0:a]old[a]')
            .set_complex_filter('[0:a]volume=0.5[a]')
            .map_stream(:video)
            .map_filter(:a)
            .metadata(title: 'Title', artist: 'Artist')
            .metadata(:language, :eng, stream: 's:0')
            .output(:stdout)
            .capture

      expect(runner).to have_received(:call).with [
        'ffmpeg', '-i', 'input.mp4', '-filter_complex', '[0:a]volume=0.5[a]',
        '-map', '0:v:0', '-map', '[a]', '-metadata', 'title=Title',
        '-metadata', 'artist=Artist', '-metadata:s:0', 'language=eng', '-'
      ]
    end

    it 'builds named rates, domain filters, and metadata policy without raw flags' do
      runner = instance_double Proc
      allow(runner).to receive(:call).and_return ['', '', status(true)]
      ffmpeg = described_class.new runner: runner, profile: :plain
      intervals = 'between(t\\,10\\,20)+between(t\\,30\\,40)'

      ffmpeg.input('input.mp4')
            .output_frame_rate(24)
            .output_sample_rate(44_100)
            .output_channels(2)
            .preserve_resolution_scale(modulus: 8)
            .decimate('hi=1024:lo=512:frac=0.40')
            .speed(1.25, stream: :video)
            .speed(1.25, stream: :audio)
            .cut_intervals(intervals, video: true, audio: true)
            .silence_intervals(intervals)
            .metadata_policy(tags: {title: '  Title  '})
            .output(:stdout)
            .capture

      expect(runner).to have_received(:call).with [
        'ffmpeg', '-i', 'input.mp4', '-r', '24', '-ar', '44100', '-ac', '2',
        '-vf', "scale=trunc(iw/8)*8:trunc(ih/8)*8,mpdecimate=hi=1024:lo=512:frac=0.40," \
               "setpts=PTS/1.25,select='not(#{intervals})',setpts=N/FRAME_RATE/TB",
        '-af', "atempo=1.25,aselect='not(#{intervals})',asetpts=N/SR/TB," \
               "volume=0:enable='#{intervals}'",
        '-map_metadata', '0', '-id3v2_version', '3', '-movflags', 'use_metadata_tags',
        '-write_id3v1', '1', '-metadata',
        'downloaded_with=t.me/media_downloader_2bot', '-metadata', 'title=Title', '-'
      ]
    end

    it 'rejects a second output' do
      ffmpeg = described_class.new runner: instance_double(Proc)
      ffmpeg.output 'first.mp4'

      expect { ffmpeg.output 'second.mp4' }
        .to raise_error ArgumentError, 'output already set'
    end

    it 'requires output for capture and run' do
      ffmpeg = described_class.new runner: instance_double(Proc)

      expect { ffmpeg.capture }.to raise_error ArgumentError, 'output is required'
      expect { ffmpeg.run! }.to raise_error ArgumentError, 'output is required'
    end

    it 'returns raw capture results and resets after success' do
      commands = []
      result = ['', '', status(true)]
      runner = lambda do |command|
        commands << command
        result
      end
      ffmpeg = described_class.new runner: runner, profile: :plain

      expect(ffmpeg.input('first.mp4').output(:stdout).capture).to equal result
      expect(ffmpeg.input('second.mp4').output(:stdout).capture).to equal result
      expect(commands).to eq [
        ['ffmpeg', '-i', 'first.mp4', '-'],
        ['ffmpeg', '-i', 'second.mp4', '-']
      ]
    end

    it 'resets after runner failure' do
      commands = []
      runner = lambda do |command|
        commands << command
        raise 'runner failed' if commands.one?

        ['', '', status(true)]
      end
      ffmpeg = described_class.new runner: runner, profile: :plain

      expect { ffmpeg.input('first.mp4').output(:stdout).capture }
        .to raise_error RuntimeError, 'runner failed'
      ffmpeg.input('second.mp4').output(:stdout).capture
      expect(commands.last).to eq ['ffmpeg', '-i', 'second.mp4', '-']
    end

    it 'returns stdout for stdout and a verified path for file output' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'output.mp4'
        runner = lambda do |command|
          File.write output, '' if command.last == output
          ['captured', '', status(true)]
        end
        ffmpeg = described_class.new runner: runner, profile: :plain

        expect(ffmpeg.input('first.mp4').output(:stdout).run!).to eq 'captured'
        expect(ffmpeg.input('second.mp4').output(output).run!).to eq output
      end
    end

    it 'asserts that file output exists and resets after assertion failure' do
      commands = []
      runner = lambda do |command|
        commands << command
        ['', 'output missing', status(true)]
      end
      ffmpeg = described_class.new runner: runner, profile: :plain

      expect { ffmpeg.input('first.mp4').output('/missing/output.mp4').run! label: 'encode failed' }
        .to raise_error Sh::Error, 'encode failed: output missing'
      ffmpeg.input('second.mp4').output(:stdout).capture
      expect(commands.last).to eq ['ffmpeg', '-i', 'second.mp4', '-']
    end

    it 'does not expose raw option or argument APIs' do
      ffmpeg = described_class.new

      expect(ffmpeg).not_to respond_to :arguments
      expect(ffmpeg).not_to respond_to :options
      expect(ffmpeg).not_to respond_to :capture_ffmpeg
      expect(ffmpeg).not_to respond_to :ffmpeg!
    end
  end

  describe '#verify!' do
    it 'parses versions using executable basenames and discards pending state' do
      commands = []
      runner = lambda do |command|
        commands << command
        ["#{File.basename command.first} version 9.1 Copyright FFmpeg", '', status(true)]
      end
      ffmpeg = described_class.new(
        ffmpeg: '/opt/ffmpeg/bin/ffmpeg',
        ffprobe: '/opt/ffmpeg/bin/ffprobe',
        runner: runner,
        profile: :plain
      )

      ffmpeg.input 'stale.mp4'
      expect { ffmpeg.verify! }.not_to raise_error
      expect(commands).to eq [
        ['/opt/ffmpeg/bin/ffmpeg', '-version'],
        ['/opt/ffmpeg/bin/ffprobe', '-version']
      ]
      ffmpeg.output(:stdout).capture
      expect(commands.last).to eq ['/opt/ffmpeg/bin/ffmpeg', '-']
    end
  end

  describe '#probe' do
    let(:runner) { instance_double Proc }
    let(:ffmpeg) { described_class.new ffprobe: '/usr/bin/ffprobe', runner: runner }
    let(:command) do
      [
        '/usr/bin/ffprobe', '-v', 'quiet', '-print_format', 'json',
        '-show_format', '-show_streams', '/media/input.mp4'
      ]
    end

    it 'returns parsed probe JSON using argv' do
      allow(runner).to receive(:call).with(command)
        .and_return ['{"format":{"duration":"1.5"}}', '', status(true)]

      expect(ffmpeg.probe('/media/input.mp4')).to eq 'format' => {'duration' => '1.5'}
    end

    it 'preserves the failure label' do
      allow(runner).to receive(:call).with(command).and_return ['', 'missing lib', status(false)]

      expect { ffmpeg.probe '/media/input.mp4' }
        .to raise_error Sh::Error, 'ffprobe failed for input.mp4: missing lib'
    end

    it 'preserves the empty output label' do
      allow(runner).to receive(:call).with(command).and_return ["\n", '', status(true)]

      expect { ffmpeg.probe '/media/input.mp4' }
        .to raise_error RuntimeError, 'ffprobe returned no output for input.mp4'
    end
  end

  describe '#encoder_available?' do
    it 'detects an exact encoder name and resets pending state' do
      commands = []
      output = " A..... aac AAC encoder\n A..... libfdk_aac Fraunhofer encoder\n"
      runner = lambda do |command|
        commands << command
        [output, '', status(true)]
      end
      ffmpeg = described_class.new runner: runner, profile: :plain

      ffmpeg.input 'stale.mp4'
      expect(ffmpeg.encoder_available?('libfdk_aac')).to be true
      expect(ffmpeg.encoder_available?('fdk_aac')).to be false
      ffmpeg.output(:stdout).capture
      expect(commands).to eq [
        %w[ffmpeg -encoders],
        %w[ffmpeg -encoders],
        %w[ffmpeg -]
      ]
    end
  end

  describe '#analyze_audio' do
    it 'captures signal analysis with the analysis profile' do
      runner = instance_double Proc
      allow(runner).to receive(:call).with([
        '/usr/bin/ffmpeg', '-hide_banner', '-nostats', '-i', '/media/voice.wav',
        '-af', 'astats=metadata=0:reset=0', '-f', 'null', '-'
      ]).and_return ['metadata', 'metrics', status(true)]
      ffmpeg = described_class.new ffmpeg: '/usr/bin/ffmpeg', runner: runner

      expect(ffmpeg.analyze_audio('/media/voice.wav', kind: :signal))
        .to eq ['metadata', 'metrics']
    end

    it 'owns the silence threshold and preserves the failure label' do
      runner = instance_double Proc
      allow(runner).to receive(:call).with([
        'ffmpeg', '-hide_banner', '-nostats', '-i', 'voice.wav',
        '-af', 'silencedetect=noise=-35dB:d=0.08', '-f', 'null', '-'
      ]).and_return ['', 'invalid audio', status(false)]
      ffmpeg = described_class.new runner: runner

      expect {
        ffmpeg.analyze_audio 'voice.wav', kind: :silence, silence_threshold_db: -35
      }.to raise_error Sh::Error, 'audio silence analysis failed: invalid audio'
    end
  end

  describe '#audio_duration' do
    it 'returns the captured ffprobe duration as a float' do
      runner = instance_double Proc
      allow(runner).to receive(:call).with([
        '/usr/bin/ffprobe', '-v', 'error', '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1', '/media/voice.wav'
      ]).and_return ["12.375\n", '', status(true)]
      ffmpeg = described_class.new ffprobe: '/usr/bin/ffprobe', runner: runner

      expect(ffmpeg.audio_duration('/media/voice.wav')).to eq 12.375
    end
  end

  describe 'semantic operations' do
    let(:commands) { [] }
    let(:runner) do
      lambda do |command|
        commands << command
        File.write command.last, '' unless command.last == '-'
        ['stdout', '', status(true)]
      end
    end
    let(:ffmpeg) { described_class.new runner: runner, threads: 2 }

    it 'extracts filtered PCM audio with input seek and duration ordering' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'reference.wav'

        expect(ffmpeg.extract_audio(
          input:       '/media/source.mp4',
          output:      output,
          start:       1.25,
          duration:    3.5,
          filter:      'highpass=f=80',
          sample_rate: 24_000,
          channels:    1,
          label:       'voice reference extraction failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-loglevel', 'error', '-y', '-ss', '1.25', '-t', '3.5',
          '-i', '/media/source.mp4', '-vn', '-af', 'highpass=f=80',
          '-ac', '1', '-ar', '24000', '-c:a', 'pcm_s16le', output
        ]]
      end
    end

    it 'extracts a voice-reference profile through semantic filter inputs' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'reference.wav'

        expect(ffmpeg.extract_audio(
          input: '/media/source.mp4', output: output, sample_rate: 24_000, channels: 1,
          filter_profile: :clone, silence_threshold_db: -35, pad_duration: 0.15,
          label: 'voice reference extraction failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-loglevel', 'error', '-y', '-i', '/media/source.mp4', '-vn', '-af',
          'highpass=f=80,afftdn=nf=-25,loudnorm=I=-16:TP=-1.5:LRA=11,apad=pad_dur=0.15',
          '-ac', '1', '-ar', '24000', '-c:a', 'pcm_s16le', output
        ]]
      end
    end

    it 'preserves raw voice-reference extraction as an unfiltered operation' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'raw.wav'

        expect(ffmpeg.extract_audio(
          input: '/media/source.mp4', output: output, sample_rate: 24_000, channels: 1,
          filter_profile: :raw, label: 'raw extraction failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-loglevel', 'error', '-y', '-i', '/media/source.mp4', '-vn',
          '-ac', '1', '-ar', '24000', '-c:a', 'pcm_s16le', output
        ]]
      end
    end

    it 'normalizes input to the transcribe.cpp WAV profile' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'transcribe.wav'

        expect(ffmpeg.transcribe_wav(
          input: '/media/source.mp3', output: output, label: 'ffmpeg failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-i', '/media/source.mp3', '-ar', '16000',
          '-ac', '1', '-c:a', 'pcm_s16le', output
        ]]
      end
    end

    it 'extracts an embedded subtitle stream as WebVTT' do
      expect(ffmpeg.convert_subtitle(
        input: '/media/video.mkv', format: :vtt, stream_index: 2, label: 'VTT extraction failed'
      )).to eq 'stdout'
      expect(commands).to eq [[
        'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error',
        '-i', '/media/video.mkv', '-map', '0:s:2', '-c:s', 'webvtt', '-f', 'webvtt', '-'
      ]]
    end

    it 'converts an external subtitle to SRT and preserves failures' do
      failure_runner = instance_double Proc
      allow(failure_runner).to receive(:call).with([
        'ffmpeg', '-y', '-threads', '4', '-loglevel', 'error',
        '-i', '/tmp/sub.vtt', '-f', 'srt', '-'
      ]).and_return ['', 'bad subtitle', status(false)]
      converter = described_class.new runner: failure_runner, threads: 4

      expect {
        converter.convert_subtitle input: '/tmp/sub.vtt', format: :srt,
                                   label: 'srt conversion failed'
      }.to raise_error Sh::Error, 'srt conversion failed: bad subtitle'
    end

    it 'remuxes audio into the existing MP4 profile' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'audio.m4a'

        expect(ffmpeg.remux_audio(
          input: '/media/audio.opus', output: output, label: 'Telegram audio remux failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-i', '/media/audio.opus', '-map', '0:a:0', '-c:a', 'copy',
          '-movflags', '+faststart', '-f', 'mp4', output
        ]]
      end
    end

    it 'normalizes mono speech at 48 kHz' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'speech.wav'

        expect(ffmpeg.normalize_dub_audio(
          input: 'raw.wav', output: output, label: 'dub audio normalization'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error',
          '-i', 'raw.wav', '-ac', '1', '-ar', '48000', output
        ]]
      end
    end

    it 'renders multiple timeline inputs with the supplied filter graph' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'timeline.wav'

        expect(ffmpeg.render_dub_timeline(
          inputs: %w[first.wav second.wav], output: output,
          filter: '[0:a][1:a]amix=inputs=2:normalize=0', label: 'dub timeline'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error',
          '-i', 'first.wav', '-i', 'second.wav', '-filter_complex',
          '[0:a][1:a]amix=inputs=2:normalize=0', '-ac', '1', '-ar', '48000', output
        ]]
      end
    end

    it 'renders timeline clips through semantic inputs and the owned graph constructor' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'timeline.wav'
        clips = [
          instance_double('clip', path: 'first.wav', start: 0.0, speed: 1.0),
          instance_double('clip', path: 'second.wav', start: 1.5, speed: 2.4),
        ]

        expect(ffmpeg.render_dub_timeline(
          clips: clips, duration: 4.0, output: output, label: 'dub timeline'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-i', 'first.wav',
          '-i', 'second.wav', '-filter_complex',
          '[0:a]adelay=0:all=1[a0];[1:a]atempo=2.000000,atempo=1.200000,' \
          'adelay=1500:all=1[a1];[a0][a1]amix=inputs=2:normalize=0,' \
          'loudnorm=I=-18:TP=-1.5:LRA=7,atrim=0:4.0',
          '-ac', '1', '-ar', '48000', output
        ]]
      end
    end

    it 'creates mono 48 kHz silence for an empty timeline' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'silence.wav'

        expect(ffmpeg.create_dub_silence(
          output: output, duration: 2.5, label: 'dub silence'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-f', 'lavfi',
          '-i', 'anullsrc=channel_layout=mono:sample_rate=48000', '-t', '2.5', output
        ]]
      end
    end

    it 'mixes speech and non-vocals while copying video' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'dubbed.mp4'
        filter = '[speech][bed]amix=inputs=2:normalize=0[a]'

        expect(ffmpeg.mux_dubbed_audio(
          video: 'video.mp4', speech: 'speech.wav', non_vocals: 'bed.wav',
          output: output, duration: 42.25, filter: filter, label: 'dub mux'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-i', 'video.mp4',
          '-i', 'speech.wav', '-i', 'bed.wav', '-filter_complex', filter,
          '-map', '0:v:0', '-map', '[a]', '-t', '42.25', '-c:v', 'copy',
          '-c:a', 'aac', '-b:a', '128k', output
        ]]
      end
    end

    it 'constructs the dubbed audio mix when no filter is supplied' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'dubbed.mp4'

        expect(ffmpeg.mux_dubbed_audio(
          video: 'video.mp4', speech: 'speech.wav', non_vocals: 'bed.wav',
          output: output, duration: 42.25, label: 'dub mux'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-i', 'video.mp4',
          '-i', 'speech.wav', '-i', 'bed.wav', '-filter_complex',
          '[1:a]aformat=sample_rates=48000:channel_layouts=stereo[speech];' \
          '[2:a]aformat=sample_rates=48000:channel_layouts=stereo[bed];' \
          '[speech][bed]amix=inputs=2:normalize=0,alimiter=limit=0.95,atrim=0:42.25[a]',
          '-map', '0:v:0', '-map', '[a]', '-t', '42.25', '-c:v', 'copy',
          '-c:a', 'aac', '-b:a', '128k', output
        ]]
      end
    end

    it 'concatenates a manifest by stream copy and validates the output' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'copy.wav'

        expect(ffmpeg.concat_audio(
          inputs: '/tmp/concat.txt', output: output, copy: true, label: 'concat failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-f', 'concat',
          '-safe', '0', '-i', '/tmp/concat.txt', '-c', 'copy', output
        ]]
      end
    end

    it 'concatenates input paths through a mapped filter with optional resampling' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'joined.wav'

        expect(ffmpeg.concat_audio(
          inputs: %w[first.wav second.wav], output: output, copy: false,
          sample_rate: 24_000, label: 'concat failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-i', 'first.wav',
          '-i', 'second.wav', '-filter_complex',
          '[0:a][1:a]concat=n=2:v=0:a=1,aresample=24000[a]', '-map', '[a]', output
        ]]
      end
    end

    it 'requires a concat manifest path for copy mode' do
      expect {
        ffmpeg.concat_audio inputs: %w[first.wav second.wav], output: '/tmp/out.wav',
                            copy: true, label: 'concat failed'
      }.to raise_error ArgumentError, 'copy concat requires a manifest path'
      expect(commands).to be_empty
    end

    it 'creates format-preserving filtered silence with exact audio options' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'silence.m4a'

        expect(ffmpeg.create_silence(
          output:         output,
          source:         'anoisesrc=color=white:amplitude=0.001:sample_rate=24000',
          duration:       3.5,
          filter:         'lowpass=f=6000',
          sample_rate:    24_000,
          channels:       2,
          channel_layout: :stereo,
          codec:          'libfdk_aac',
          codec_profile:  'aac_he',
          bitrate:        32_004,
          sample_format:  :fltp,
          label:          'silence failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-f', 'lavfi', '-i',
          'anoisesrc=color=white:amplitude=0.001:sample_rate=24000',
          '-af', 'lowpass=f=6000', '-t', '3.5', '-ar', '24000', '-ac', '2',
          '-channel_layout', 'stereo', '-c:a', 'libfdk_aac', '-profile:a', 'aac_he',
          '-b:a', '32004', '-sample_fmt:a', 'fltp', output
        ]]
      end
    end

    it 'creates semantic noise with the owned source and filter inputs' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'silence.m4a'

        expect(ffmpeg.create_silence(
          output: output, duration: 3.5, sample_rate: 24_000, channels: 2,
          channel_layout: :stereo, amplitude: 0.001, codec: 'libfdk_aac',
          codec_profile: 'aac_he', bitrate: 32_004, sample_format: :fltp,
          label: 'silence failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-f', 'lavfi', '-i',
          'anoisesrc=color=white:amplitude=0.001:sample_rate=24000',
          '-af', 'lowpass=f=6000', '-t', '3.5', '-ar', '24000', '-ac', '2',
          '-channel_layout', 'stereo', '-c:a', 'libfdk_aac', '-profile:a', 'aac_he',
          '-b:a', '32004', '-sample_fmt:a', 'fltp', output
        ]]
      end
    end

    it 'defaults semantic silence to a mono 48 kHz lavfi source' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'silence.wav'

        expect(ffmpeg.create_silence(
          output: output, duration: 1.0, label: 'silence failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-f', 'lavfi', '-i',
          'anullsrc=channel_layout=mono:sample_rate=48000', '-t', '1.0', output
        ]]
      end
    end

    it 'preserves a semantic source sample rate without forcing output format options' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'silence.wav'

        expect(ffmpeg.create_silence(
          output: output, source_sample_rate: 24_000, duration: 1.0, label: 'silence failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-f', 'lavfi', '-i',
          'anullsrc=channel_layout=mono:sample_rate=24000', '-t', '1.0', output
        ]]
      end
    end

    it 'adds an audio floor using two named inputs and a complex filter' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'floor.wav'
        filter = '[0:a]loudnorm=I=-18[speech];[1:a]lowpass=f=6000[floor];' \
                 '[speech][floor]amix=inputs=2:normalize=0'

        expect(ffmpeg.add_audio_floor(
          input: 'speech.wav', source: 'anoisesrc=sample_rate=24000', output: output,
          filter: filter, sample_rate: 24_000, label: 'floor failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-i', 'speech.wav',
          '-f', 'lavfi', '-i', 'anoisesrc=sample_rate=24000', '-filter_complex', filter,
          '-ac', '1', '-ar', '24000', '-c:a', 'pcm_s16le', output
        ]]
      end
    end

    it 'constructs the audio floor source and graph from semantic inputs' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'floor.wav'

        expect(ffmpeg.add_audio_floor(
          input: 'speech.wav', output: output, amplitude: 0.001,
          loudness_lufs: -18, sample_rate: 24_000, label: 'floor failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-i', 'speech.wav',
          '-f', 'lavfi', '-i', 'anoisesrc=color=white:amplitude=0.001:sample_rate=24000',
          '-filter_complex',
          '[0:a]loudnorm=I=-18:TP=-2:LRA=11[speech];[1:a]lowpass=f=6000[floor];' \
          '[speech][floor]amix=inputs=2:duration=first:dropout_transition=0:normalize=0,' \
          'alimiter=limit=0.841395:attack=5:release=50:level=false',
          '-ac', '1', '-ar', '24000', '-c:a', 'pcm_s16le', output
        ]]
      end
    end

    it 'applies a validated speech speed filter and writes PCM audio' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'speed.wav'
        filter = 'rubberband=tempo=1.2:pitch=1:formant=preserved'

        expect(ffmpeg.speed_audio(
          input: 'speech.wav', output: output, filter: filter, label: 'speed failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-i', 'speech.wav',
          '-af', filter, '-c:a', 'pcm_s16le', output
        ]]
      end
    end

    it 'constructs the speech speed filter from a semantic speed' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'speed.wav'

        expect(ffmpeg.speed_audio(
          input: 'speech.wav', output: output, speed: 1.2, label: 'speed failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-i', 'speech.wav',
          '-af', 'rubberband=tempo=1.2:pitch=1:transients=smooth:detector=soft:' \
                 'phase=laminar:window=long:formant=preserved',
          '-c:a', 'pcm_s16le', output
        ]]
      end
    end

    it 'converts audio to a caller-owned WAV path with optional rate and channels' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'audio.wav'

        expect(ffmpeg.audio_to_wav(
          input: 'audio.mp3', output: output, sample_rate: 16_000, channels: 1,
          label: 'wav failed'
        )).to eq output
        expect(commands).to eq [[
          'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-i', 'audio.mp3',
          '-ac', '1', '-ar', '16000', output
        ]]
      end
    end

    it 'does not inherit or retain builder state around convenience calls' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'speech.wav'
        ffmpeg.input 'stale.mp4'

        ffmpeg.normalize_dub_audio input: 'raw.wav', output: output, label: 'normalize'
        ffmpeg.output(:stdout).capture

        expect(commands).to eq [
          [
            'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error',
            '-i', 'raw.wav', '-ac', '1', '-ar', '48000', output
          ],
          ['ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-']
        ]
      end
    end

    it 'isolates the new one-shot operations from pending builder state' do
      Dir.mktmpdir do |dir|
        output = File.join dir, 'audio.wav'
        ffmpeg.input 'stale.mp4'

        ffmpeg.audio_to_wav input: 'audio.mp3', output: output, label: 'wav failed'
        ffmpeg.output(:stdout).capture

        expect(commands).to eq [
          [
            'ffmpeg', '-y', '-threads', '2', '-loglevel', 'error',
            '-i', 'audio.mp3', output
          ],
          ['ffmpeg', '-y', '-threads', '2', '-loglevel', 'error', '-']
        ]
      end
    end
  end
end
