require 'spec_helper'
require_relative '../../lib/dubbing/audio'

RSpec.describe Dubbing::Audio do
  let(:dir) { Dir.mktmpdir('dub-audio-spec-') }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def probe_duration(path, duration, ffmpeg: anything, leading: 0.0, trailing: 0.0)
    file_duration = duration + leading + trailing
    allow(Prober).to receive(:for).with(path, ffmpeg: ffmpeg)
      .and_return(SymMash.new(format: SymMash.new(duration: file_duration)))
    allow(described_class::SpeechSpan).to receive(:detect).with(path, ffmpeg: ffmpeg).and_return(
      described_class::SpeechSpan.new(
        duration: file_duration, leading: leading, trailing: trailing, speech: duration
      )
    )
  end

  it 'preserves synthesized edge padding without changing speech speed' do
    input = File.join(dir, 'input.wav')
    output = File.join(dir, 'output.wav')
    ffmpeg = instance_double FFmpeg
    expect(ffmpeg).to receive(:normalize_dub_audio).with(
      input: input, output: output, label: 'dub audio normalization'
    ).and_return output

    expect(described_class.normalize(input, output, ffmpeg: ffmpeg)).to eq(output)
  end

  it 'fits tempo to audible speech instead of synthesized leading pad' do
    clip = described_class::Clip.new(path: File.join(dir, 'speech.wav'), start: 0.0, end: 2.0)
    probe_duration clip.path, 2.0, leading: 0.4

    scheduled = described_class.schedule([clip], duration: 4.0)

    expect(scheduled.first.speed).to eq(1.0)
    expect(scheduled.first.leading).to eq(0.4)
    expect(scheduled.first.speech).to eq(2.0)
    expect([scheduled.first.start, scheduled.first.end]).to eq([0.0, 2.0])
  end

  it 'uses the gap after a sentence before speeding it up' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 1.5)
    second = described_class::Clip.new(path: File.join(dir, 'second.wav'), start: 2.0, end: 4.0)
    probe_duration first.path, 2.4
    probe_duration second.path, 2.0

    scheduled = described_class.schedule([first, second], duration: 5.0)

    expect(scheduled.map(&:start)).to eq([0.0, 2.0])
    expect(scheduled.first.end).to eq(2.0)
    expect(scheduled.first.speed).to be_within(0.001).of(2.4 / 2.0)
    expect(scheduled.last.speed).to eq(1.0)
  end

  it 'centers shorter speech in its source interval at natural speed' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 2.0)
    second = described_class::Clip.new(path: File.join(dir, 'second.wav'), start: 3.0, end: 4.0)
    probe_duration first.path, 1.0
    probe_duration second.path, 2.0

    scheduled = described_class.schedule([first, second], duration: 5.0)

    expect(scheduled.first.speed).to eq(1.0)
    expect([scheduled.first.start, scheduled.first.end]).to eq([0.5, 1.5])
    expect([scheduled.last.start, scheduled.last.end]).to eq([2.0, 4.0])
  end

  it 'centers shorter speech inside the source interval available before the video ends' do
    clip = described_class::Clip.new(path: File.join(dir, 'speech.wav'), start: 4.0, end: 6.0)
    probe_duration clip.path, 0.4

    scheduled = described_class.schedule([clip], duration: 5.0)

    expect(scheduled.first.speed).to eq(1.0)
    expect(scheduled.first.start).to be_within(0.001).of(4.3)
    expect(scheduled.first.end).to be_within(0.001).of(4.7)
  end

  it 'keeps every sentence from a multi-sentence subtitle at or above natural speed' do
    subtitle = Subtitler::Subtitle::Entry.new(
      text: 'First sentence. Second sentence.', start: 1.0, finish: 5.0, words: []
    )
    sentences = Subtitler::Subtitle.new(entries: [subtitle]).sentence_entries
    clips = sentences.map.with_index do |sentence, idx|
      described_class::Clip.new(path: File.join(dir, "sentence-#{idx}.wav"), start: sentence.start, end: sentence.finish)
    end
    clips.each do |clip|
      probe_duration clip.path, 0.5
    end

    scheduled = described_class.schedule(clips, duration: 6.0)

    expect(sentences.size).to eq(2)
    expect(scheduled.map(&:speed)).to all(be >= 1.0)
  end

  it 'rejects scheduled clips below natural speed' do
    expect do
      described_class::ScheduledClip.new(path: 'speech.wav', start: 0.0, end: 2.0, speed: 0.5)
    end.to raise_error(ArgumentError, 'dubbed speech speed cannot be below 1x')
  end

  it 'rejects rendering below natural speed' do
    expect { described_class.tempo_filter(0.5) }
      .to raise_error(ArgumentError, 'dubbed speech speed cannot be below 1x')
  end

  it 'builds tempo factors through FFmpeg speed filters' do
    expect(FFmpeg).to receive(:speed_filter).with('2.000000', stream: :audio)
      .and_return('atempo=2.000000')
    expect(FFmpeg).to receive(:speed_filter).with('1.200000', stream: :audio)
      .and_return('atempo=1.200000')

    expect(described_class.tempo_filter(2.4)).to eq 'atempo=2.000000,atempo=1.200000'
  end

  it 'uses gaps before and after a sentence to avoid speeding it up' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 1.0)
    middle = described_class::Clip.new(path: File.join(dir, 'middle.wav'), start: 2.0, end: 3.0)
    last = described_class::Clip.new(path: File.join(dir, 'last.wav'), start: 4.0, end: 5.0)
    probe_duration first.path, 1.0
    probe_duration middle.path, 3.0
    probe_duration last.path, 1.0

    scheduled = described_class.schedule([first, middle, last], duration: 5.0)

    expect(scheduled.map(&:speed)).to eq([1.0, 1.0, 1.0])
    expect(scheduled[1].start).to eq(1.0)
    expect(scheduled[1].end).to eq(4.0)
  end

  it 'shares a gap between neighboring sentences without overlapping them' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 1.0)
    second = described_class::Clip.new(path: File.join(dir, 'second.wav'), start: 2.0, end: 3.0)
    probe_duration first.path, 3.0
    probe_duration second.path, 3.0

    scheduled = described_class.schedule([first, second], duration: 3.0)

    expect(scheduled.map(&:speed)).to eq([2.0, 2.0])
    expect(scheduled.first.end).to eq(1.5)
    expect(scheduled.last.start).to eq(1.5)
  end

  it 'uses the required speed even when it exceeds the former ceiling' do
    first = described_class::Clip.new(path: File.join(dir, 'first.wav'), start: 0.0, end: 1.0)
    second = described_class::Clip.new(path: File.join(dir, 'second.wav'), start: 2.0, end: 4.0)
    probe_duration first.path, 4.0
    probe_duration second.path, 2.0

    scheduled = described_class.schedule([first, second], duration: 5.0)

    expect(scheduled.first.speed).to eq(2.0)
    expect(scheduled.first.end).to eq(2.0)
    expect(scheduled.last.start).to eq(2.0)
  end

  it 'caps a sentence at its speaker pace and overruns into the slack ahead of it' do
    clips = [[0.0, 4.0, 4.0], [4.0, 8.0, 4.0], [8.0, 9.0, 1.5], [9.0, 13.0, 2.0]].map.with_index do |(start, finish, length), idx|
      path = File.join(dir, "sentence-#{idx}.wav")
      probe_duration path, length
      described_class::Clip.new(path: path, start: start, end: finish)
    end

    scheduled = described_class.schedule(clips, duration: 13.0)

    expect(scheduled[2].speed).to be_within(0.001).of(1.15)
    expect(scheduled[2].end).to be_within(0.001).of(9.304)
    expect(scheduled[3].start).to be >= scheduled[2].end
  end

  it 'allows a faster speaker the pace it already sustains' do
    slow = [['a', 0.0, 4.0, 4.0], ['a', 4.0, 8.0, 4.0], ['a', 8.0, 9.0, 1.5]]
    fast = [['b', 9.0, 13.0, 5.6], ['b', 13.0, 17.0, 5.6], ['b', 17.0, 18.0, 1.5]]
    clips = (slow + fast).map.with_index do |(speaker, start, finish, length), idx|
      path = File.join(dir, "sentence-#{idx}.wav")
      probe_duration path, length
      described_class::Clip.new(path: path, start: start, end: finish, speaker_id: speaker)
    end

    scheduled = described_class.schedule(clips, duration: 18.0)

    expect(scheduled[2].speed).to be_within(0.001).of(1.15)
    expect(scheduled[5].speed).to be_within(0.001).of(1.5)
  end

  it 'never compresses a sentence past the intelligible maximum' do
    clip = described_class::Clip.new(path: File.join(dir, 'speech.wav'), start: 0.0, end: 1.0)
    probe_duration clip.path, 8.0

    scheduled = described_class.schedule([clip], duration: 1.0)

    expect(scheduled.first.speed).to eq(2.0)
  end

  it 'normalizes the rendered dialogue mix to broadcast speech loudness' do
    input  = File.join(dir, 'input.wav')
    output = File.join(dir, 'output.wav')
    clip   = described_class::Clip.new(path: input, start: 0.0, end: 2.0)
    ffmpeg = instance_double FFmpeg
    probe_duration input, 1.5, ffmpeg: ffmpeg
    allow(FFmpeg).to receive(:dub_timeline_filter).and_call_original
    expect(ffmpeg).to receive(:render_dub_timeline) do |**arguments|
      expect(arguments[:inputs]).to eq [input]
      expect(arguments[:output]).to eq output
      expect(arguments[:filter]).to include('amix=inputs=1:normalize=0', 'loudnorm=I=-18:TP=-1.5:LRA=7')
      expect(arguments[:filter]).not_to include('atempo')
      expect(arguments[:label]).to eq 'dub timeline'
      output
    end

    described_class.render_timeline([clip], output, duration: 3.0, ffmpeg: ffmpeg)

    expect(FFmpeg).to have_received(:dub_timeline_filter).with(
      clips: [an_instance_of(described_class::ScheduledClip)], duration: 3.0
    )
  end

  it 'trims synthesized leading pad before placing speech on the timeline' do
    input  = File.join(dir, 'input.wav')
    output = File.join(dir, 'output.wav')
    clip   = described_class::Clip.new(path: input, start: 0.5, end: 2.0)
    ffmpeg = instance_double FFmpeg
    probe_duration input, 1.5, leading: 0.2, ffmpeg: ffmpeg
    allow(FFmpeg).to receive(:dub_timeline_filter).and_call_original
    expect(ffmpeg).to receive(:render_dub_timeline) do |**arguments|
      expect(arguments[:filter]).to include(
        'atrim=start=0.2:duration=1.5', 'asetpts=PTS-STARTPTS', 'adelay=500:all=1'
      )
      expect(arguments[:filter]).not_to include('atempo')
      output
    end

    described_class.render_timeline([clip], output, duration: 3.0, ffmpeg: ffmpeg)
  end

  it 'creates silence through FFmpeg for an empty timeline' do
    output = File.join(dir, 'output.wav')
    ffmpeg = instance_double FFmpeg
    expect(ffmpeg).to receive(:create_dub_silence).with(
      output: output, duration: 3.0, label: 'dub silence'
    ).and_return output

    timeline = described_class.render_timeline([], output, duration: 3.0, ffmpeg: ffmpeg)

    expect(timeline.path).to eq output
    expect(timeline.clips).to be_empty
  end

  it 'mixes the non-vocal stem under generated speech' do
    output = File.join(dir, 'output.mp4')
    ffmpeg = instance_double FFmpeg
    allow(FFmpeg).to receive(:dub_audio_mix_filter).and_call_original
    expect(ffmpeg).to receive(:mux_dubbed_audio) do |**arguments|
      expect(arguments[:video]).to eq 'video.mp4'
      expect(arguments[:speech]).to eq 'dub.wav'
      expect(arguments[:non_vocals]).to eq 'no-vocals.wav'
      expect(arguments[:output]).to eq output
      expect(arguments[:duration]).to eq 6.0
      expect(arguments[:filter]).to include('amix=inputs=2:normalize=0', 'alimiter=limit=0.95')
      expect(arguments[:label]).to eq 'dub mux'
      output
    end

    described_class.replace_video_audio(
      'video.mp4', 'dub.wav', 'no-vocals.wav', output, duration: 6.0, ffmpeg: ffmpeg
    )

    expect(FFmpeg).to have_received(:dub_audio_mix_filter).with(duration: 6.0)
  end
end
