require 'rails_helper'

RSpec.describe Dubbing::TargetVoice do
  let(:dir) { Dir.mktmpdir('target-voice-spec-') }
  let(:reference) { TTS::Reference.new(path: File.join(dir, 'speaker.wav'), text: 'English reference.') }

  let(:durations) { Hash.new(2.0) }
  let(:ffmpeg)    { instance_double(FFmpeg).tap { |ffmpeg| allow(ffmpeg).to receive(:audio_duration) { |path| durations[File.basename(path)] } } }

  after { FileUtils.remove_entry(dir) }

  it 'keeps the candidate closest to the recorded voice and clones it with the text it speaks' do
    allow(TTS).to receive(:synthesize_batch) { |items:, **| items.each { |item| File.write(item.fetch(:out_path), 'raw') } }
    scorer = ->(sample:, **) { {cosine_similarity: sample.end_with?('-3.wav') ? 0.8 : 0.4} }

    voice = described_class.new(reference, text: 'Olá, tudo bem?', lang: 'pt', options: {}, scorer: scorer, ffmpeg: ffmpeg).call

    expect(voice).to eq(TTS::Reference.new(path: File.join(dir, 'target-voice-3.wav'), text: 'Olá, tudo bem?'))
    expect(TTS).to have_received(:synthesize_batch).with(
      hash_including(speaker_wav: reference.path, ref_text: reference.text, items: have_attributes(size: described_class::CANDIDATES))
    )
  end

  it 'leaves out the candidates too short to carry a voice' do
    allow(TTS).to receive(:synthesize_batch) { |items:, **| items.each { |item| File.write(item.fetch(:out_path), 'raw') } }
    durations['target-voice-3.wav'] = 0.02
    scorer = ->(sample:, **) { {cosine_similarity: sample.end_with?('-3.wav') ? 0.9 : 0.4} }

    voice = described_class.new(reference, text: 'Olá.', lang: 'pt', options: {}, scorer: scorer, ffmpeg: ffmpeg).call

    expect(voice.path).to eq(File.join(dir, 'target-voice-1.wav'))
  end

  it 'makes no voice when every candidate is too short' do
    allow(TTS).to receive(:synthesize_batch) { |items:, **| items.each { |item| File.write(item.fetch(:out_path), 'raw') } }
    durations.default = 0.02
    scorer = ->(**) { raise 'scored' }

    expect(described_class.new(reference, text: 'Olá.', lang: 'pt', options: {}, scorer: scorer, ffmpeg: ffmpeg).call).to be_nil
  end
end
