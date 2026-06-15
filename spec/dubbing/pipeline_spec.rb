require 'spec_helper'
require_relative '../../lib/dubbing'

RSpec.describe Dubbing::Pipeline do
  let(:dir) { Dir.mktmpdir('dub-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }
  let(:probe) { SymMash.new(format: SymMash.new(duration: 6.0), streams: [SymMash.new(codec_type: 'video')]) }
  let(:status) { instance_double(Bot::Status::Line, update: nil) }

  before { File.write(input, 'video') }
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

  it 'skips dubbing when source language already matches the target language' do
    allow(Subtitler).to receive(:transcribe).and_return(transcript(lang: 'pt'))
    expect(TTS).not_to receive(:synthesize)

    output = described_class.apply(input, dir: dir, opts: SymMash.new(dub: 1), stl: status, probe: probe)

    expect(output).to eq(input)
  end

  it 'translates and synthesizes one sentence at a time with the extracted speaker reference' do
    speaker = File.join(dir, 'speaker.wav')
    File.write(speaker, 'speaker')

    pipeline = described_class.new(input, dir: dir, opts: SymMash.new(dub: 1), stl: status, probe: probe)
    allow(Subtitler).to receive(:transcribe).and_return(transcript)
    allow(::Translator).to receive(:translate).and_return(['Olá.', 'Tchau.'])
    allow(Dubbing::VoiceReference).to receive(:extract).and_return(speaker)
    allow(pipeline).to receive(:fit_clip) { |_raw, out, _duration| File.write(out, 'fit') }
    allow(pipeline).to receive(:assemble_timeline).and_return(File.join(dir, 'dub.wav'))
    allow(pipeline).to receive(:mix_video).and_return(File.join(dir, 'out.mp4'))

    expect(TTS).to receive(:synthesize).with(
      text: 'Olá.',
      lang: 'pt',
      out_path: kind_of(String),
      temperature: 0,
      speaker_wav: speaker
    ) { |out_path:, **_| File.write(out_path, 'raw') }
    expect(TTS).to receive(:synthesize).with(
      text: 'Tchau.',
      lang: 'pt',
      out_path: kind_of(String),
      temperature: 0,
      speaker_wav: speaker
    ) { |out_path:, **_| File.write(out_path, 'raw') }

    pipeline.apply

    expect(::Translator).to have_received(:translate).with(['Hello.', 'Bye.'], from: 'en', to: 'pt')
    expect(Dubbing::VoiceReference).to have_received(:extract).with(input, pipeline.sentences, dir: kind_of(String))
  end

  it 'speeds up long synthesized speech to fit the original sentence slot' do
    pipeline = described_class.new(input, dir: dir, opts: SymMash.new(dub: 1), probe: probe)
    raw = File.join(dir, 'raw.wav')
    fit = File.join(dir, 'fit.wav')
    File.write(raw, 'raw')

    allow(Prober).to receive(:for).with(raw).and_return(SymMash.new(format: SymMash.new(duration: 3.0)))
    expect(Sh).to receive(:run) do |cmd|
      expect(cmd).to include('atempo\\=3.0')
      File.write(fit, 'fit')
      ['', '', ok_status]
    end

    pipeline.send(:fit_clip, raw, fit, 1.0)
  end

  it 'ducks original audio when mixing the dubbed track into a video with audio' do
    audio_probe = SymMash.new(
      format: SymMash.new(duration: 6.0),
      streams: [
        SymMash.new(codec_type: 'video'),
        SymMash.new(codec_type: 'audio'),
      ]
    )
    pipeline = described_class.new(input, dir: dir, opts: SymMash.new(dub: 1), probe: audio_probe)
    dub_audio = File.join(dir, 'dub.wav')
    File.write(dub_audio, 'dub')

    expect(Sh).to receive(:run) do |cmd|
      expect(cmd).to include('sidechaincompress')
      expect(cmd).to include('amix')
      out = cmd.split.last
      File.write(out, 'video')
      ['', '', ok_status]
    end

    output = pipeline.send(:mix_video, dub_audio, dir)

    expect(output).to eq(File.join(dir, 'dubbed-input.mp4'))
    expect(File.exist?(output)).to be(true)
  end
end
