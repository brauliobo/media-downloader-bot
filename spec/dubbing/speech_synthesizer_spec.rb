require 'spec_helper'
require_relative '../../lib/dubbing/speech_synthesizer'

RSpec.describe Dubbing::SpeechSynthesizer do
  let(:dir) { Dir.mktmpdir('speech-synthesizer-spec-') }
  let(:reference) { Dubbing::VoiceReference::Reference.new(path: File.join(dir, 'source.wav'), text: 'English reference.') }
  let(:sentences) do
    [
      sentence('Sim.', 0.0, 1.0, 'speaker'),
      sentence('Esta é uma frase longa para aquecer a voz.', 1.5, 4.0, 'speaker')
    ]
  end

  def sentence(text, start, finish, speaker_id)
    Subtitler::Subtitle::Entry.new(
      text: text, start: start, finish: finish, speaker_id: speaker_id
    )
  end

  before do
    File.write(reference.path, 'source')
    allow(TTS).to receive(:supports?).and_return(true)
    allow(Dubbing::Audio).to receive(:normalize) do |_input, output|
      File.write(output, 'fit')
    end
    allow(Dubbing::Audio).to receive(:render_timeline) do |clips, output, duration:|
      Dubbing::Audio::Timeline.new(path: output, clips: clips)
    end
  end

  after do
    FileUtils.remove_entry(dir) if Dir.exist?(dir)
  end

  it 'rejects subtitle hashes' do
    expect do
      described_class.new(
        sentences: [{text: 'Sim.'}], references: {}, opts: SymMash.new,
        target_lang: 'pt', workdir: dir, video_duration: 1.0
      )
    end.to raise_error(TypeError, /Subtitle::Entry/)
  end

  it 'warms each speaker with target-language audio before synthesizing jobs' do
    calls = []
    allow(TTS).to receive(:synthesize_batch) do |items:, **options|
      calls << {items: items, options: options}
      items.each { |item| File.write(item.fetch(:out_path), 'raw') }
    end

    described_class.new(
      sentences:      sentences,
      references:     {'speaker' => reference},
      opts:           SymMash.new,
      target_lang:    'pt',
      workdir:        dir,
      video_duration: 5.0
    ).render

    expect(calls.size).to eq(2)
    expect(calls.first.fetch(:items).map { |item| item.fetch(:text) }).to eq([sentences.last.text])
    expect(calls.first.fetch(:options)).to include(speaker_wav: reference.path, ref_text: reference.text)
    expect(calls.last.fetch(:items).map { |item| item.fetch(:text) }).to eq(sentences.map(&:text))
    expect(calls.last.fetch(:options)).to include(ref_text: sentences.last.text)
    expect(calls.last.fetch(:options).fetch(:speaker_wav)).to end_with('speaker-0000.target-reference.wav')
  end

  it 'reports normalization progress before timeline rendering' do
    updates = []
    status = double(update: nil)
    allow(status).to receive(:update) { |message| updates << message }
    allow(TTS).to receive(:synthesize_batch) do |items:, on_batch: nil, **|
      items.each { |item| File.write(item.fetch(:out_path), 'raw') }
      on_batch&.call(items)
    end

    described_class.new(
      sentences:      sentences,
      references:     {'speaker' => reference},
      opts:           SymMash.new,
      target_lang:    'pt',
      workdir:        dir,
      video_duration: 5.0,
      stl:            status
    ).render

    expect(updates).to include(
      'dubbing: preparing speaker voice 1/1',
      'dubbing: synthesizing 2/2',
      'dubbing: normalizing speech 1/2',
      'dubbing: normalizing speech 2/2'
    )
    expect(updates.index('dubbing: preparing speaker voice 1/1')).to be < updates.index('dubbing: synthesizing 2/2')
    expect(updates.last).to eq('dubbing: rendering speech')
  end

  it 'uses the default voice for a speaker without a usable reference' do
    missing_reference_sentence = sentence('Voz padrão.', 4.0, 5.0, 'missing')
    calls = []
    allow(TTS).to receive(:supports?).and_return(false)
    allow(TTS).to receive(:synthesize_batch) do |items:, **options|
      calls << {items: items, options: options}
      items.each { |item| File.write(item.fetch(:out_path), 'raw') }
    end

    described_class.new(
      sentences:      sentences + [missing_reference_sentence],
      references:     {'speaker' => reference},
      opts:           SymMash.new,
      target_lang:    'pt',
      workdir:        dir,
      video_duration: 5.0
    ).render

    expect(calls.size).to eq(2)
    expect(calls.last.fetch(:items).map { |item| item.fetch(:text) }).to eq(['Voz padrão.'])
    expect(calls.last.fetch(:options)).not_to include(:speaker_wav, :ref_text)
  end
end
