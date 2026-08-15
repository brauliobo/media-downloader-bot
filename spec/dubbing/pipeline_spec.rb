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
      {dub: 'es-MX'}                        => 'es',
    }.each do |options, expected|
      opts = SymMash.new(options)
      Processors::Base.normalize_options(opts)
      pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
      expect(pipeline.target_lang).to eq(expected)
    end
  end

  it 'generates target subtitles without gensubs for dub language shorthand' do
    opts = SymMash.new(dub: 'pt')
    Processors::Base.normalize_options(opts)
    pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
    pipeline.instance_variable_set(
      :@sentences,
      [SymMash.new(text: 'Boa tarde.', start: 0.5, end: 1.5)]
    )

    pipeline.send(:prepare_translated_subtitles)

    expect(opts.sub_lang).to eq('pt')
    expect(opts.sub_vtt).to include('00:00:00.500 --> 00:00:01.500', 'Boa tarde.')
  end

  it 'preserves scheduled word highlighting unless nowords is requested' do
    allow(::Translator).to receive(:translate_for_dubbing).and_return(['Muito bom dia, amigo.'])
    source = SymMash.new(
      segments: [
        SymMash.new(
          text: 'Hello world.', start: 0.0, end: 1.0,
          words: [
            SymMash.new(word: 'Hello', start: 0.0, end: 0.5),
            SymMash.new(word: 'world.', start: 0.5, end: 1.0)
          ]
        )
      ]
    )
    speech = File.join(dir, 'speech.wav')
    write_silent_wav(speech, duration: 3.0)

    results = [false, true].to_h do |nowords|
      opts = SymMash.new(dub: 'pt', nowords: nowords)
      Processors::Base.normalize_options(opts)
      pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
      pipeline.instance_variable_set(:@source_lang, 'en')
      sentences = pipeline.send(:translated_sentences, source)
      clip = Dubbing::Audio::Clip.new(path: speech, start: 0.0, end: 1.0)
      timeline = Dubbing::Audio.render_timeline([clip], File.join(dir, "dub-#{nowords}.wav"), duration: 1.5)
      pipeline.instance_variable_set(:@sentences, sentences)
      pipeline.send(:apply_scheduled_timings!, timeline.clips)
      pipeline.send(:prepare_translated_subtitles)
      ass = Subtitler::Ass.from_vtt(opts.sub_vtt, mode: nowords ? :plain : :instagram)

      [nowords, {sentence: sentences.first, vtt: opts.sub_vtt, ass: ass}]
    end

    default = results.fetch(false)
    plain   = results.fetch(true)

    expect(results.values.map { |result| result[:sentence].source_words.map(&:word) })
      .to all(eq(['Hello', 'world.']))
    expect(results.values.map { |result| result[:sentence].words.map(&:word) })
      .to all(eq(['Muito', 'bom', 'dia,', 'amigo.']))
    expect(results.values.map { |result| result[:sentence].words.map { |word| [word.start, word.end] } })
      .to all(eq([[0.0, 0.375], [0.375, 0.75], [0.75, 1.125], [1.125, 1.5]]))
    expect(default[:vtt]).to include(
      '00:00:00.000 --> 00:00:01.500',
      'Muito <00:00:00.375>bom <00:00:00.750>dia, <00:00:01.125>amigo.'
    )
    expect(plain[:vtt]).to include('00:00:00.000 --> 00:00:01.500', 'Muito bom dia, amigo.')
    expect(plain[:vtt]).not_to include('<00:00:')

    highlighted = default[:ass].lines.grep(/^Dialogue:/)
    unhighlighted = plain[:ass].lines.grep(/^Dialogue:/)
    expect(highlighted.size).to eq(4)
    expect(highlighted.last).to include('0:00:01.13,0:00:01.50', '{\\1c&Hffffff&}', '{\\1c&HC0C0C0&}')
    expect(unhighlighted).to contain_exactly(include('0:00:00.00,0:00:01.50', 'Muito bom dia, amigo.'))
    expect(unhighlighted.first).not_to include('{\\1c')
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

  it 'translates alternate subtitles from scheduled dubbed sentences' do
    opts = SymMash.new(dub: 'pt', sub: 'es', sub_mode: 'language', sub_lang: 'es')
    pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
    sentence = SymMash.new(
      text: 'Boa tarde.', start: 4.0, end: 6.0,
      words: [
        SymMash.new(word: 'Boa', start: 4.0, end: 5.0),
        SymMash.new(word: 'tarde.', start: 5.0, end: 6.0),
      ]
    )
    pipeline.instance_variable_set(:@sentences, [sentence])
    pipeline.instance_variable_set(:@source_lang, 'en')
    pipeline.instance_variable_set(
      :@transcript_output,
      SymMash.new(segments: [SymMash.new(text: 'Hello.', start: 0.0, end: 1.0, words: [])])
    )
    allow(::Translator).to receive(:translate).and_return(['Buenas tardes.'])
    expect(pipeline).not_to receive(:source_subtitle_vtt)

    pipeline.send(:prepare_translated_subtitles)

    expect(::Translator).to have_received(:translate).with(['Boa tarde.'], from: 'pt', to: 'es')
    expect(opts.sub_lang).to eq('es')
    expect(opts.sub_vtt).to include(
      '00:00:04.000 --> 00:00:06.000',
      'Buenas <00:00:05.000>tardes.'
    )
    expect(sentence.text).to eq('Boa tarde.')
    expect(sentence.words.map(&:word)).to eq(['Boa', 'tarde.'])
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

  it 'omits translated subtitles for zero-duration scheduled clips' do
    opts = SymMash.new(dub: 'pt', sub_mode: 'both')
    pipeline = described_class.new(input, dir: dir, opts: opts, probe: probe)
    sentences = [
      SymMash.new(
        text: 'Olá.', source_text: 'Hello.', start: 1.0, end: 2.0,
        words: [SymMash.new(word: 'Olá.', start: 1.0, end: 2.0)]
      ),
      SymMash.new(
        text: 'Tchau.', source_text: 'Bye.', start: 2.0, end: 3.0,
        words: [SymMash.new(word: 'Tchau.', start: 2.0, end: 3.0)]
      )
    ]
    clips = [
      Dubbing::Audio::ScheduledClip.new(path: 'first.wav', start: 0.0, end: 2.0, speed: 1.0),
      Dubbing::Audio::ScheduledClip.new(path: 'second.wav', start: 3.0, end: 3.0, speed: 1.0)
    ]
    pipeline.instance_variable_set(:@sentences, sentences)

    pipeline.send(:apply_scheduled_timings!, clips)
    translated_vtt = pipeline.send(:translated_subtitle_vtt)
    translated_ass = Subtitler::Ass.from_vtt(translated_vtt)
    pipeline.send(:prepare_translated_subtitles)

    expect(pipeline.sentences).to contain_exactly(sentences.first)
    expect(pipeline.sentences.first.words.map { |word| [word.start, word.end] }).to eq([[0.0, 2.0]])
    expect(translated_vtt).to include('00:00:00.000 --> 00:00:02.000', 'Olá.')
    expect(translated_vtt).not_to include('Tchau.', '00:00:03.000 --> 00:00:03.000')
    expect(translated_ass.lines.grep(/^Dialogue:/)).to contain_exactly(
      include('0:00:00.00,0:00:02.00', 'Olá.')
    )
    expect(opts.sub_vtt).to include('Hello.', 'Olá.')
    expect(opts.sub_vtt).not_to include('Bye.', 'Tchau.', '00:00:03.000 --> 00:00:03.000')
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
