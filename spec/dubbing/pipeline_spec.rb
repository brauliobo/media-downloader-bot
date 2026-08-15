require 'spec_helper'
require_relative '../../lib/dubbing'

RSpec.describe Dubbing::Pipeline do
  let(:dir) { Dir.mktmpdir('dub-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }
  let(:vocals) { File.join(dir, 'vocals.wav') }
  let(:non_vocals) { File.join(dir, 'no-vocals.wav') }
  let(:stems) { VoiceSeparator::Stems.new(vocals: vocals, non_vocals: non_vocals) }
  let(:probe) { SymMash.new(format: SymMash.new(duration: 6.0), streams: [SymMash.new(codec_type: 'video')]) }
  let(:status) { instance_double(Bot::Status::Line, update: nil) }

  before do
    File.write(input, 'video')
    File.write(vocals, 'vocals')
    File.write(non_vocals, 'non-vocals')
    allow(VoiceSeparator).to receive(:with_stems).and_yield(stems)
  end
  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def transcript(lang: 'en')
    SymMash.new(
      lang: lang,
      output: SymMash.new(
        segments: [
          SymMash.new(text: 'Hello.', start: 0.0, end: 1.0, words: []),
          SymMash.new(text: 'Bye.', start: 2.0, end: 3.0, words: []),
        ]
      )
    )
  end

  def write_silent_wav(path, duration:)
    sample_rate = 8_000
    data_size   = (duration * sample_rate * 2).to_i
    header      = [
      'RIFF', 36 + data_size, 'WAVE', 'fmt ', 16, 1, 1,
      sample_rate, sample_rate * 2, 2, 16, 'data', data_size
    ].pack('A4VA4A4VvvVVvvA4V')
    File.binwrite(path, header + ("\0" * data_size))
  end

  def ok_status
    instance_double(Process::Status, success?: true)
  end

  it 'resolves the dubbing target independently' do
    {
      {dub: 1}                              => 'pt',
      {dub: 1, slang: 'es'}                 => 'es',
      {dub: 1, dub_lang: 'pt', slang: 'es'} => 'pt',
    }.each do |options, expected|
      pipeline = described_class.new(input, dir: dir, opts: SymMash.new(options), probe: probe)
      expect(pipeline.target_lang).to eq(expected)
    end
  end

  it 'reuses translated sentences as generated subtitles' do
    opts = SymMash.new(dub: 1, gensubs: 1, slang: 'pt')
    pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
    pipeline.instance_variable_set(
      :@sentences,
      [SymMash.new(text: 'Boa tarde.', start: 0.5, end: 1.5)]
    )

    pipeline.send(:prepare_translated_subtitles)

    expect(opts.sub_lang).to eq('pt')
    expect(opts.sub_vtt).to include('00:00:00.500 --> 00:00:01.500', 'Boa tarde.')
  end

  it 'generates target subtitles without gensubs for dub language shorthand' do
    opts = SymMash.new(dub: 1, dub_lang: 'pt', sub: 'pt', sub_mode: 'language', sub_lang: 'pt')
    pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
    pipeline.instance_variable_set(
      :@sentences,
      [SymMash.new(text: 'Boa tarde.', start: 0.5, end: 1.5)]
    )

    pipeline.send(:prepare_translated_subtitles)

    expect(opts.sub_lang).to eq('pt')
    expect(opts.sub_vtt).to include('00:00:00.500 --> 00:00:01.500', 'Boa tarde.')
  end

  it 'generates translated subtitles from the rendered speech schedule' do
    opts = SymMash.new(dub: 1, gensubs: 1, slang: 'pt')
    pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
    pipeline.instance_variable_set(:@source_lang, 'en')
    allow(::Translator).to receive(:translate_for_dubbing).and_return(['Olá mundo.', 'Tchau.'])
    source = SymMash.new(
      segments: [
        SymMash.new(
          text: 'Hello world.', start: 0.0, end: 1.0,
          words: [
            SymMash.new(word: 'Hello', start: 0.0, end: 0.5),
            SymMash.new(word: 'world.', start: 0.5, end: 1.0)
          ]
        ),
        SymMash.new(
          text: 'Bye.', start: 2.0, end: 3.0,
          words: [SymMash.new(word: 'Bye.', start: 2.0, end: 3.0)]
        )
      ]
    )
    sentences = pipeline.send(:translated_sentences, source)
    sentences.each_with_index { |sentence, index| sentence.speaker_id = index }
    clips = sentences.map.with_index do |sentence, index|
      path = File.join(dir, "speech-#{index}.wav")
      write_silent_wav(path, duration: 3.0)
      Dubbing::Audio::Clip.new(path: path, start: sentence.start, end: sentence.end)
    end

    timeline = Dubbing::Audio.render_timeline(clips, File.join(dir, 'dub.wav'), duration: 3.0)
    pipeline.instance_variable_set(:@sentences, sentences)
    pipeline.send(:apply_scheduled_timings!, timeline.clips)
    pipeline.send(:prepare_translated_subtitles)

    expect(File).to exist(timeline.path)
    expect(sentences.first.source_words.map(&:word)).to eq(['Hello', 'world.'])
    expect(sentences.map(&:words)).to eq([[], []])
    expect(opts.sub_vtt).to include('00:00:00.000 --> 00:00:01.500', 'Olá mundo.')
    expect(opts.sub_vtt).to include('00:00:01.500 --> 00:00:03.000', 'Tchau.')
    expect(opts.sub_vtt).not_to include('<00:00:')
  end

  it 'reuses source sentences for sub=source' do
    opts = SymMash.new(dub: 1, sub: 'source', sub_mode: 'source')
    pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
    pipeline.instance_variable_set(
      :@transcript_output,
      SymMash.new(segments: [SymMash.new(text: 'Hello.', start: 0.0, end: 1.0, words: [])])
    )
    pipeline.instance_variable_set(:@source_lang, 'en')

    pipeline.send(:prepare_translated_subtitles)

    expect(opts.sub_lang).to eq('en')
    expect(opts.sub_vtt).to include('00:00:00.000 --> 00:00:01.000', 'Hello.')
  end

  it 'builds bilingual subtitles for sub=both' do
    opts = SymMash.new(dub: 1, sub: 'both', sub_mode: 'both')
    pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
    pipeline.instance_variable_set(
      :@sentences,
      [SymMash.new(source_text: 'Hello.', text: 'Olá.', start: 0.0, end: 1.0)]
    )

    pipeline.send(:prepare_translated_subtitles)

    expect(opts.sub_lang).to eq('mul')
    expect(opts.sub_vtt).to include('Hello.', 'Olá.')
  end

  it 'skips dubbing when source language already matches the target language' do
    allow(Subtitler).to receive(:transcribe).and_return(transcript(lang: 'pt'))
    expect(TTS).not_to receive(:synthesize)

    output = described_class.apply(input, dir: dir, opts: SymMash.new(dub: 1), stl: status, probe: probe)

    expect(output).to eq(input)
    expect(Subtitler).to have_received(:transcribe).with(vocals, separate_voice: false)
  end

  it 'translates and batch synthesizes with each extracted speaker reference' do
    speaker_paths = {
      0 => File.join(dir, 'speaker-0.wav'),
      1 => File.join(dir, 'speaker-1.wav'),
    }
    speaker_paths.each_value { |path| File.write(path, 'speaker') }
    speakers = {
      0 => Dubbing::VoiceReference::Reference.new(path: speaker_paths.fetch(0), text: 'Hello.'),
      1 => Dubbing::VoiceReference::Reference.new(path: speaker_paths.fetch(1), text: 'Bye.'),
    }
    diarization = SymMash.new(segments: [
      SymMash.new(start: 0.0, end: 1.0, speaker_id: 0),
      SymMash.new(start: 2.0, end: 3.0, speaker_id: 1),
    ])

    opts = SymMash.new(dub: 1)
    pipeline = described_class.new(input, dir: dir, opts: opts, stl: status, probe: probe)
    allow(Subtitler).to receive(:transcribe).and_return(transcript)
    allow(::Translator).to receive(:translate_for_dubbing).and_return(['Olá.', 'Tchau.'])
    allow(Diarizer).to receive(:diarize).and_return(diarization)
    allow(Dubbing::VoiceReference).to receive(:extract_by_speaker).and_return(speakers)
    allow(TTS).to receive(:supports?).and_return(false)
    allow(Dubbing::Audio).to receive(:normalize) { |_raw, out| File.write(out, 'fit') }
    allow(Dubbing::Audio).to receive(:render_timeline) do |clips, output, **|
      Dubbing::Audio::Timeline.new(path: output, clips: clips)
    end
    allow(pipeline).to receive(:mix_video).and_return(File.join(dir, 'out.mp4'))

    expect(TTS).to receive(:synthesize_batch).with(
      items: [hash_including(text: 'Olá.', lang: 'pt', out_path: kind_of(String))],
      on_batch: kind_of(Proc),
      threads: 1,
      speaker_wav: speaker_paths.fetch(0),
      ref_text: 'Hello.'
    ) { |items:, **_| items.each { |item| File.write(item.fetch(:out_path), 'raw') } }
    expect(TTS).to receive(:synthesize_batch).with(
      items: [hash_including(text: 'Tchau.', lang: 'pt', out_path: kind_of(String))],
      on_batch: kind_of(Proc),
      threads: 1,
      speaker_wav: speaker_paths.fetch(1),
      ref_text: 'Bye.'
    ) { |items:, **_| items.each { |item| File.write(item.fetch(:out_path), 'raw') } }

    pipeline.apply

    expect(::Translator).to have_received(:translate_for_dubbing)
      .with(['Hello.', 'Bye.'], from: 'en', to: 'pt', durations: [1.0, 1.0])
    expect(Dubbing::VoiceReference).to have_received(:extract_by_speaker)
      .with(
        vocals,
        diarization.segments,
        sentences:   kind_of(Array),
        dir:         kind_of(String),
        transcriber: kind_of(VoiceReference::Transcriber)
      )
    expect(pipeline.sentences.map(&:speaker_id)).to eq([0, 1])
    expect(pipeline.sentences.map(&:source_text)).to eq(['Hello.', 'Bye.'])
    expect(Diarizer).to have_received(:diarize).with(vocals, speakers: nil)
  end

  it 'uses the default voice without removing sentences whose speaker has no usable reference' do
    speaker_path = File.join(dir, 'speaker-0.wav')
    File.write(speaker_path, 'speaker')
    reference = Dubbing::VoiceReference::Reference.new(path: speaker_path, text: 'Hello.')
    diarization = SymMash.new(segments: [
      SymMash.new(start: 0.0, end: 1.0, speaker_id: 0),
      SymMash.new(start: 2.0, end: 3.0, speaker_id: 1),
    ])
    pipeline = described_class.new(input, dir: dir, opts: SymMash.new(dub: 1), probe: probe)
    allow(Subtitler).to receive(:transcribe).and_return(transcript)
    allow(::Translator).to receive(:translate_for_dubbing).and_return(['Olá.', 'Tchau.'])
    allow(Diarizer).to receive(:diarize).and_return(diarization)
    allow(Dubbing::VoiceReference).to receive(:extract_by_speaker).and_return(0 => reference)
    allow(TTS).to receive(:supports?).and_return(false)
    allow(TTS).to receive(:synthesize_batch) do |items:, **|
      items.each { |item| File.write(item.fetch(:out_path), 'raw') }
    end
    allow(Dubbing::Audio).to receive(:normalize) { |_raw, out| File.write(out, 'fit') }
    allow(Dubbing::Audio).to receive(:render_timeline) do |clips, output, **|
      Dubbing::Audio::Timeline.new(path: output, clips: clips)
    end
    allow(pipeline).to receive(:mix_video).and_return(File.join(dir, 'out.mp4'))

    pipeline.apply

    expect(pipeline.sentences.map(&:speaker_id)).to eq([0, 1])
    expect(TTS).to have_received(:synthesize_batch).with(
      items: [hash_including(text: 'Olá.')],
      on_batch: kind_of(Proc),
      threads: 1,
      speaker_wav: speaker_path,
      ref_text: 'Hello.'
    )
    expect(TTS).to have_received(:synthesize_batch).with(
      items: [hash_including(text: 'Tchau.')],
      on_batch: kind_of(Proc),
      threads: 1
    )
  end

  it 'dubs every sentence with the default voice when no speaker has a usable reference' do
    diarization = SymMash.new(segments: [SymMash.new(start: 0.0, end: 3.0, speaker_id: 0)])
    pipeline = described_class.new(input, dir: dir, opts: SymMash.new(dub: 1), probe: probe)
    allow(Subtitler).to receive(:transcribe).and_return(transcript)
    allow(::Translator).to receive(:translate_for_dubbing).and_return(['Olá.', 'Tchau.'])
    allow(Diarizer).to receive(:diarize).and_return(diarization)
    allow(Dubbing::VoiceReference).to receive(:extract_by_speaker).and_return({})
    allow(TTS).to receive(:supports?).and_return(false)
    allow(TTS).to receive(:synthesize_batch) do |items:, **|
      items.each { |item| File.write(item.fetch(:out_path), 'raw') }
    end
    allow(Dubbing::Audio).to receive(:normalize) { |_raw, out| File.write(out, 'fit') }
    allow(Dubbing::Audio).to receive(:render_timeline) do |clips, output, **|
      Dubbing::Audio::Timeline.new(path: output, clips: clips)
    end
    output = File.join(dir, 'out.mp4')
    allow(pipeline).to receive(:mix_video).and_return(output)

    result = pipeline.apply

    expect(result).to eq(output)
    expect(pipeline.sentences.map(&:text)).to eq(['Olá.', 'Tchau.'])
    expect(TTS).to have_received(:synthesize_batch).with(
      items: [hash_including(text: 'Olá.'), hash_including(text: 'Tchau.')],
      on_batch: kind_of(Proc),
      threads: 1
    )
  end

  it 'fails when scheduled clips do not match translated sentences' do
    pipeline = described_class.new(input, dir: dir, opts: SymMash.new(dub: 1), probe: probe)
    sentences = [
      SymMash.new(text: 'Olá.', start: 0.0, end: 1.0, words: []),
      SymMash.new(text: 'Tchau.', start: 2.0, end: 3.0, words: [])
    ]
    clips = [Dubbing::Audio::ScheduledClip.new(path: 'clip.wav', start: 0.0, end: 1.0, speed: 1.0)]
    pipeline.instance_variable_set(:@sentences, sentences)

    expect { pipeline.send(:apply_scheduled_timings!, clips) }
      .to raise_error(RuntimeError, 'dubbed timeline clip count mismatch: expected 2, got 1')
  end

  it 'keeps generated subtitle cues within the shared maximum length' do
    opts = SymMash.new(dub: 1, gensubs: 1, slang: 'pt')
    pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
    pipeline.instance_variable_set(
      :@sentences,
      [SymMash.new(
        text: 'Esta é uma frase muito longa com palavras suficientes para exigir a divisão em mais de uma legenda legível.',
        start: 0.0,
        end: 4.0,
        speaker_id: 0
      )]
    )

    pipeline.send(:prepare_translated_subtitles)

    payloads = opts.sub_vtt.split(/\n\s*\n/).filter_map do |cue|
      lines = cue.lines.map(&:strip)
      timing = lines.find { |line| line.include?('-->') }
      next unless timing

      lines[(lines.index(timing) + 1)..].join(' ')
    end

    expect(payloads).not_to be_empty
    expect(payloads).to all(have_attributes(length: be <= Subtitler::Translator::MAX_SUBTITLE_CHARS))
  end

  it 'writes an opt-in timing score for future evaluations' do
    report = File.join(dir, 'timing.json')
    pipeline = described_class.new(input, dir: dir, opts: SymMash.new(dub: 1, dubscore: report), probe: probe)
    pipeline.instance_variable_set(:@timing_score, {version: 1, deviation_index: 42.5})

    pipeline.send(:write_timing_score)

    expect(JSON.parse(File.read(report))).to eq('version' => 1, 'deviation_index' => 42.5)
  end

end
