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

  def ok_status
    instance_double(Process::Status, success?: true)
  end

  it 'defaults dub target language to Portuguese' do
    pipeline = described_class.new(input, dir: dir, opts: SymMash.new(dub: 1), probe: probe)

    expect(pipeline.target_lang).to eq('pt')
  end

  it 'uses explicit lang option when present' do
    pipeline = described_class.new(input, dir: dir, opts: SymMash.new(dub: 1, slang: 'es'), probe: probe)

    expect(pipeline.target_lang).to eq('es')
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
    opts = SymMash.new(dub: 1, slang: 'pt', sub: 'pt', sub_mode: 'language', sub_lang: 'pt')
    pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
    pipeline.instance_variable_set(
      :@sentences,
      [SymMash.new(text: 'Boa tarde.', start: 0.5, end: 1.5)]
    )

    pipeline.send(:prepare_translated_subtitles)

    expect(opts.sub_lang).to eq('pt')
    expect(opts.sub_vtt).to include('00:00:00.500 --> 00:00:01.500', 'Boa tarde.')
  end

  it 'keeps source-projected highlighting without aligning synthesized speech' do
    opts = SymMash.new(dub: 1, slang: 'pt', sub_mode: 'language', sub_lang: 'pt')
    pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
    pipeline.instance_variable_set(:@source_lang, 'en')
    allow(::Translator).to receive(:translate_for_dubbing).and_return(['Olá mundo.'])
    source = SymMash.new(
      segments: [SymMash.new(
        text: 'Hello world.', start: 0.0, end: 2.0,
        words: [
          SymMash.new(word: 'Hello', start: 0.0, end: 1.0),
          SymMash.new(word: 'world.', start: 1.0, end: 2.0)
        ]
      )]
    )

    sentences = pipeline.send(:translated_sentences, source)
    pipeline.instance_variable_set(:@sentences, sentences)
    pipeline.send(:prepare_translated_subtitles)

    expect(sentences.first.source_words.map(&:word)).to eq(['Hello', 'world.'])
    expect(sentences.first.words.map(&:word)).to eq(['Olá', 'mundo.'])
    expect(opts.sub_vtt).to include('<00:00:01.000>mundo.')
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

    opts = SymMash.new(dub: 1, gensubs: 1)
    pipeline = described_class.new(input, dir: dir, opts: opts, stl: status, probe: probe)
    allow(Subtitler).to receive(:transcribe).and_return(transcript)
    allow(::Translator).to receive(:translate_for_dubbing).and_return(['Olá.', 'Tchau.'])
    allow(Diarizer).to receive(:diarize).and_return(diarization)
    allow(Dubbing::VoiceReference).to receive(:extract_by_speaker).and_return(speakers)
    allow(TTS).to receive(:supports?).and_return(false)
    allow(Dubbing::Audio).to receive(:normalize) { |_raw, out| File.write(out, 'fit') }
    allow(Dubbing::Audio).to receive(:render_timeline) do |clips, output, duration:|
      expect(duration).to eq(6.0)
      scheduled = [
        Dubbing::Audio::ScheduledClip.new(path: clips.fetch(0).path, start: 0.0, end: 1.5, speed: 1.0),
        Dubbing::Audio::ScheduledClip.new(path: clips.fetch(1).path, start: 2.0, end: 3.0, speed: 1.0),
      ]
      Dubbing::Audio::Timeline.new(path: output, clips: scheduled)
    end
    allow(Dubbing::Audio).to receive(:replace_video_audio) do |_video, _speech, _non_vocals, out, **_|
      File.write(out, 'video')
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
    expect(pipeline.sentences.map(&:start)).to eq([0.0, 2.0])
    expect(opts.sub_vtt).to include('00:00:00.000 --> 00:00:01.000', 'Olá.')
    expect(opts.sub_vtt).to include('00:00:02.000 --> 00:00:03.000', 'Tchau.')
    expect(opts.sub_vtt).not_to include('Olá. Tchau.')
    expect(Diarizer).to have_received(:diarize).with(vocals, speakers: nil)
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
