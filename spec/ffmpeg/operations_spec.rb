require 'rails_helper'

RSpec.describe FFmpeg::Operations do
  let(:dir)      { Dir.mktmpdir('ffmpeg-operations-') }
  let(:calls)    { [] }
  let(:status)   { Struct.new(:success?, :exitstatus).new(true, 0) }
  let(:runner)   { ->(command) { calls << command.map(&:to_s); File.write(command.last, '') unless command.last == '-'; ['', '', status] } }
  let(:ffmpeg)   { FFmpeg.new(runner: runner) }
  let(:interval) { ->(start, finish) { Utils::TimeRanges::Interval.new(start, finish) } }

  after { FileUtils.remove_entry dir }

  def path(name) = File.join(dir, name)

  # The commands run, with the scratch directories the operation made for itself named by what they are for.
  def commands = calls.map { |call| call.join(' ').gsub(dir, '<dir>').gsub(%r{(?<=/)([a-z-]+)-\d{8}-\d+-\w+}, '\1') }

  def clips(count) = Array.new(count) { |index| FFmpeg::MixedDubClip.new(path: "c#{index}.wav", start: index.to_f) }

  it 'extracts audio from a window of the input' do
    ffmpeg.extract_audio input: 'in.mp4', output: path('out.wav'), sample_rate: 16_000, channels: 1, label: 'x', start: 1.5, duration: 3

    expect(commands).to eq ['ffmpeg -loglevel error -y -ss 1.5 -t 3 -i in.mp4 -vn -ac 1 -ar 16000 -c:a pcm_s16le <dir>/out.wav']
  end

  it 'filters the extracted audio' do
    ffmpeg.extract_audio input: 'in.mp4', output: path('out.wav'), sample_rate: 16_000, channels: 1, label: 'x', filter: 'highpass=f=80'

    expect(commands).to eq ['ffmpeg -loglevel error -y -i in.mp4 -vn -af highpass=f=80 -ac 1 -ar 16000 -c:a pcm_s16le <dir>/out.wav']
  end

  it 'extracts the speech ranges in one pass' do
    ranges = Utils::TimeRanges.new([interval.(0.0, 1.0), interval.(2.0, 3.0)], option: :vad)

    ffmpeg.extract_speech_ranges input: 'in.wav', output: path('out.wav'), ranges: ranges, sample_rate: 16_000, channels: 1, label: 'x'

    expect(commands).to eq [
      "ffmpeg -loglevel error -y -i in.wav -vn -af aselect='between(t\\,0\\,1)+between(t\\,2\\,3)',asetpts=N/SR/TB " \
      '-ac 1 -ar 16000 -c:a pcm_s16le <dir>/out.wav'
    ]
  end

  it 'extracts many speech ranges in chunks and joins them' do
    ranges = Utils::TimeRanges.new(Array.new(FFmpeg::Filters::MAX_SELECT_TERMS + 2) { |i| interval.(i * 2.0, i * 2.0 + 1) }, option: :vad)

    ffmpeg.extract_speech_ranges input: 'in.wav', output: path('out.wav'), ranges: ranges, sample_rate: 16_000, channels: 1, label: 'x'

    expect(commands.size).to eq 3
    expect(commands.first).to end_with '-c:a pcm_s16le /tmp/speech-ranges/0.wav'
    expect(commands.second).to include('between(t\,200\,201)+between(t\,202\,203)').and end_with('/tmp/speech-ranges/1.wav')
    expect(commands.third).to eq 'ffmpeg -y -threads 5 -loglevel error -f concat -safe 0 -i /tmp/speech-ranges/concat.txt -c copy <dir>/out.wav'
  end

  it 'converts a wav for transcription' do
    ffmpeg.transcribe_wav input: 'in.mp4', output: path('out.wav'), label: 'x'

    expect(commands).to eq ['ffmpeg -y -i in.mp4 -ar 16000 -ac 1 -c:a pcm_s16le <dir>/out.wav']
  end

  it 'converts a subtitle stream to webvtt on stdout' do
    ffmpeg.convert_subtitle input: 'in.mkv', format: :vtt, label: 'x', stream_index: 2

    expect(commands).to eq ['ffmpeg -y -threads 5 -loglevel error -i in.mkv -map 0:s:2 -c:s webvtt -f webvtt -']
  end

  it 'converts a subtitle to another format as is' do
    ffmpeg.convert_subtitle input: 'in.mkv', format: :srt, label: 'x'

    expect(commands).to eq ['ffmpeg -y -threads 5 -loglevel error -i in.mkv -f srt -']
  end

  it 'remuxes the audio stream into an mp4 container' do
    ffmpeg.remux_audio input: 'in.mp4', output: path('out.m4a'), label: 'x'

    expect(commands).to eq ['ffmpeg -y -i in.mp4 -map 0:a:0 -c:a copy -movflags +faststart -f mp4 <dir>/out.m4a']
  end

  it 'copies the audio stream out' do
    ffmpeg.extract_copy_audio input: 'in.mp4', output: path('out.m4a'), label: 'x'

    expect(commands).to eq ['ffmpeg -loglevel error -y -i in.mp4 -vn -c:a copy <dir>/out.m4a']
  end

  it 'normalizes dub audio to mono 48 kHz' do
    ffmpeg.normalize_dub_audio input: 'in.wav', output: path('out.wav'), label: 'x'

    expect(commands).to eq ['ffmpeg -y -threads 5 -loglevel error -i in.wav -ac 1 -ar 48000 <dir>/out.wav']
  end

  it 'makes dub silence' do
    ffmpeg.create_dub_silence output: path('out.wav'), duration: 2, label: 'x'

    expect(commands).to eq ['ffmpeg -y -threads 5 -loglevel error -f lavfi -i anullsrc=channel_layout=mono:sample_rate=48000 -t 2.0 <dir>/out.wav']
  end

  it 'mixes the dubbed speech and the non-vocals over the video' do
    ffmpeg.mux_dubbed_audio video: 'v.mp4', speech: 's.wav', non_vocals: 'n.wav', output: path('out.mp4'), duration: 6.0, label: 'x'

    expect(commands).to eq [
      'ffmpeg -y -threads 5 -loglevel error -i v.mp4 -i s.wav -i n.wav -filter_complex ' \
      '[1:a]aformat=sample_rates=48000:channel_layouts=stereo[speech];[2:a]aformat=sample_rates=48000:channel_layouts=stereo[bed];' \
      '[speech][bed]amix=inputs=2:normalize=0,alimiter=limit=0.95,atrim=0:6.0[a] ' \
      '-map 0:v:0 -map [a] -t 6.0 -c:v copy -c:a aac -b:a 128k <dir>/out.mp4'
    ]
  end

  it 'concatenates by manifest without re-encoding' do
    ffmpeg.concat_audio inputs: 'list.txt', output: path('out.wav'), copy: true, label: 'x'

    expect(commands).to eq ['ffmpeg -y -threads 5 -loglevel error -f concat -safe 0 -i list.txt -c copy <dir>/out.wav']
  end

  it 'concatenates by filter and resamples' do
    ffmpeg.concat_audio inputs: %w[a.wav b.wav], output: path('out.wav'), copy: false, sample_rate: 24_000, label: 'x'

    expect(commands).to eq [
      'ffmpeg -y -threads 5 -loglevel error -i a.wav -i b.wav -filter_complex [0:a][1:a]concat=n=2:v=0:a=1,aresample=24000[a] ' \
      "-map [a] <dir>/out.wav"
    ]
  end

  it 'refuses a copy concat without a manifest path' do
    expect { ffmpeg.concat_audio inputs: %w[a.wav], output: path('out.wav'), copy: true, label: 'x' }.to raise_error(ArgumentError, /manifest/)
  end

  it 'makes silence' do
    ffmpeg.create_silence output: path('out.wav'), duration: 2, label: 'x'

    expect(commands).to eq ['ffmpeg -y -threads 5 -loglevel error -f lavfi -i anullsrc=channel_layout=mono:sample_rate=48000 -t 2 <dir>/out.wav']
  end

  it 'makes a low noise floor in the requested encoding' do
    ffmpeg.create_silence output: path('out.mp3'), duration: 2, label: 'x', amplitude: 0.001, sample_rate: 24_000, channels: 1,
                          channel_layout: :mono, codec: 'libmp3lame', bitrate: 64_000, sample_format: 's16'

    expect(commands).to eq [
      'ffmpeg -y -threads 5 -loglevel error -f lavfi -i anoisesrc=color=white:amplitude=0.001:sample_rate=24000 -af lowpass=f=6000 ' \
      '-t 2 -ar 24000 -ac 1 -channel_layout mono -c:a libmp3lame -b:a 64000 -sample_fmt:a s16 <dir>/out.mp3'
    ]
  end

  it 'adds an audio floor under the speech' do
    ffmpeg.add_audio_floor input: 'in.wav', output: path('out.wav'), sample_rate: 24_000, label: 'x', amplitude: 0.001, loudness_lufs: -18

    expect(commands).to eq [
      'ffmpeg -y -threads 5 -loglevel error -i in.wav -f lavfi -i anoisesrc=color=white:amplitude=0.001:sample_rate=24000 -filter_complex ' \
      '[0:a]loudnorm=I=-18:TP=-2:LRA=11[speech];[1:a]lowpass=f=6000[floor];' \
      '[speech][floor]amix=inputs=2:duration=first:dropout_transition=0:normalize=0,alimiter=limit=0.841395:attack=5:release=50:level=false ' \
      '-ac 1 -ar 24000 -c:a pcm_s16le <dir>/out.wav'
    ]
  end

  it 'changes the audio speed keeping the pitch' do
    ffmpeg.reencode_audio input: 'in.wav', output: path('out.wav'), label: 'x', speed: 1.2

    expect(commands).to eq [
      'ffmpeg -y -threads 5 -loglevel error -i in.wav ' \
      '-af rubberband=tempo=1.2:pitch=1:transients=smooth:detector=soft:phase=laminar:window=long:formant=preserved ' \
      '-c:a pcm_s16le <dir>/out.wav'
    ]
  end

  it 'encodes audio with a codec at a bitrate, without a filter unless asked' do
    ffmpeg.reencode_audio input: 'in.wav', output: path('out.opus'), label: 'x', codec: 'libopus', bitrate: 64_000

    expect(commands).to eq ['ffmpeg -y -threads 5 -loglevel error -i in.wav -c:a libopus -b:a 64000 <dir>/out.opus']
  end

  it 'pads an audio shorter than a minimum, after the speed' do
    ffmpeg.reencode_audio input: 'in.wav', output: path('out.opus'), label: 'x', speed: 1.2, min_duration: 0.02, codec: 'libopus', bitrate: 64_000

    expect(commands).to eq [
      'ffmpeg -y -threads 5 -loglevel error -i in.wav ' \
      '-af rubberband=tempo=1.2:pitch=1:transients=smooth:detector=soft:phase=laminar:window=long:formant=preserved,apad=whole_dur=0.02 ' \
      '-c:a libopus -b:a 64000 <dir>/out.opus'
    ]
  end

  it 'converts audio to wav' do
    ffmpeg.audio_to_wav input: 'in.mp3', output: path('out.wav'), sample_rate: 16_000, channels: 1, label: 'x'

    expect(commands).to eq ['ffmpeg -y -threads 5 -loglevel error -i in.mp3 -ac 1 -ar 16000 <dir>/out.wav']
  end

  it 'renders the dub timeline through a filter script' do
    ffmpeg.render_dub_timeline clips: clips(3), duration: 5.0, output: path('out.wav'), label: 'x'

    expect(commands).to eq [
      'ffmpeg -y -threads 5 -loglevel error -i c0.wav -i c1.wav -i c2.wav -/filter_complex /tmp/dub-timeline/filter.txt -ac 1 -ar 48000 <dir>/out.wav'
    ]
  end

  it 'mixes a long dub timeline in batches first' do
    ffmpeg.render_dub_timeline clips: clips(FFmpeg::DUB_MIX_BATCH + 1), duration: 200.0, output: path('out.wav'), label: 'x'

    expect(commands.size).to eq 3
    expect(commands.first).to include('-c:a pcm_f32le').and end_with('/tmp/dub-timeline/batches/0.wav')
    expect(commands.second).to include('-i c100.wav').and end_with('/tmp/dub-timeline/batches/1.wav')
    expect(commands.third).to include('-i /tmp/dub-timeline/batches/0.wav -i /tmp/dub-timeline/batches/1.wav').and end_with('<dir>/out.wav')
  end
end
