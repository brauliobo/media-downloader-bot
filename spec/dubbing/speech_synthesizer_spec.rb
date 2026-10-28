require 'rails_helper'

RSpec.describe Dubbing::SpeechSynthesizer do
  let(:dir) { Dir.mktmpdir('speech-synthesizer-spec-') }
  let(:reference) { TTS::Reference.new(path: File.join(dir, 'source.wav'), text: 'English reference.') }
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

  it 'clones every sentence of a speaker from the speaker recorded reference, not from a synthesized anchor' do
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

    expect(calls.size).to eq(1)
    expect(calls.first.fetch(:items).map { |item| item.fetch(:text) }).to eq(sentences.map(&:text))
    expect(calls.first.fetch(:options)).to include(speaker_wav: reference.path, ref_text: reference.text)
    expect(calls.first.fetch(:options)).not_to include(:threads)
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
      'dubbing: audio 2/2',
      'dubbing: normalizing speech 1/2',
      'dubbing: normalizing speech 2/2'
    )
    expect(updates.last).to eq('dubbing: rendering speech')
  end

  it 'uses the default voice for a speaker without a usable reference' do
    missing_reference_sentence = sentence('Voz padrão.', 4.0, 5.0, 'missing')
    calls = []
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

  it 'translates each sentence on the way and drops the ones left with nothing to say' do
    spoken = []
    allow(TTS).to receive(:synthesize_batch) do |items:, **|
      spoken.concat(items.map { |item| item.fetch(:text) })
      items.each { |item| File.write(item.fetch(:out_path), 'raw') }
    end
    translations = {'Sim.' => 'Yes.', 'Esta é uma frase longa para aquecer a voz.' => ''}
    synthesizer = described_class.new(
      sentences:      sentences,
      references:     {'speaker' => reference},
      opts:           SymMash.new,
      target_lang:    'en',
      workdir:        dir,
      video_duration: 5.0,
      translate:      ->(sentence) { translations.fetch(sentence.text) }
    )

    timeline = synthesizer.render

    expect(spoken).to eq(['Yes.'])
    expect(synthesizer.sentences).to eq([sentences.first])
    expect(timeline.clips.size).to eq(1)
  end
end
