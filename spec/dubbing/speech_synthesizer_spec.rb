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

  before do
    allow_any_instance_of(VoiceClone::EmbeddingScorer).to receive(:call).and_return(cosine_similarity: 0.5)
    allow_any_instance_of(FFmpeg).to receive(:audio_duration).and_return(2.0)
  end

  after do
    FileUtils.remove_entry(dir) if Dir.exist?(dir)
  end

  it 'clones every sentence of a speaker from the best of several target language copies of the recorded reference' do
    calls = []
    allow(TTS).to receive(:synthesize_batch) do |items:, **options|
      calls << {items: items, options: options}
      items.each_with_index { |item, idx| File.write(item.fetch(:out_path), "raw#{idx}") }
    end
    allow_any_instance_of(VoiceClone::EmbeddingScorer).to receive(:call) do |_scorer, **args|
      {cosine_similarity: args[:sample].end_with?('-2.wav') ? 0.9 : 0.5}
    end

    described_class.new(
      sentences:      sentences,
      references:     {'speaker' => reference},
      opts:           SymMash.new,
      target_lang:    'pt',
      workdir:        dir,
      video_duration: 5.0
    ).render

    anchors, speech = calls
    expect(anchors.fetch(:items).map { |item| item.fetch(:text) }).to eq([sentences.last.text] * Dubbing::TargetVoice::CANDIDATES)
    expect(anchors.fetch(:options)).to include(speaker_wav: reference.path, ref_text: reference.text)
    expect(speech.fetch(:items).map { |item| item.fetch(:text) }).to eq(sentences.map(&:text))
    expect(speech.fetch(:options)).to include(speaker_wav: File.join(dir, 'target-voice-2.wav'), ref_text: sentences.last.text)
  end

  def render_with(sentences)
    described_class.new(
      sentences: sentences, references: {'speaker' => reference}, opts: SymMash.new, target_lang: 'pt', workdir: dir, video_duration: 5.0
    ).render
  end

  it 'keeps the recorded reference of a speaker whose longest sentence has nothing to say' do
    calls = []
    allow(TTS).to receive(:synthesize_batch) do |items:, **options|
      calls << options
      items.each { |item| File.write(item.fetch(:out_path), 'raw') }
    end

    render_with([sentence('Sim.', 0.0, 1.0, 'speaker'), sentence('🇺🇦🇸🇪🇬🇧 ...', 1.5, 4.0, 'speaker')])

    expect(calls).to all(include(speaker_wav: reference.path))
    expect(calls.size).to eq(1)
  end

  it 'keeps the recorded reference of a speaker whose target voice candidates are all too short' do
    calls = []
    allow(TTS).to receive(:synthesize_batch) do |items:, **options|
      calls << options
      items.each { |item| File.write(item.fetch(:out_path), 'raw') }
    end
    allow_any_instance_of(FFmpeg).to receive(:audio_duration).and_return(0.02)

    render_with(sentences)

    expect(calls.last).to include(speaker_wav: reference.path, ref_text: reference.text)
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

    expect(calls.size).to eq(3)
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
