require 'spec_helper'
require_relative '../../lib/dubbing/speech_synthesizer'

RSpec.describe Dubbing::SpeechSynthesizer do
  let(:dir) { Dir.mktmpdir('speech-synthesizer-spec-') }
  let(:reference) { Dubbing::VoiceReference::Reference.new(path: File.join(dir, 'source.wav'), text: 'English reference.') }
  let(:sentences) do
    [
      SymMash.new(text: 'Sim.', start: 0.0, end: 1.0, speaker_id: 'speaker'),
      SymMash.new(text: 'Esta é uma frase longa para aquecer a voz.', start: 1.5, end: 4.0, speaker_id: 'speaker')
    ]
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
end
