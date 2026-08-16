require 'spec_helper'
require_relative '../../lib/voice_reference'

RSpec.describe VoiceReference do
  it 'separates unique sources once, preserves order, and keeps stems through selection' do
    Dir.mktmpdir('voice-reference-sources-') do |dir|
      sources     = %w[first.webm second.webm first.webm]
      output      = File.join(dir, 'reference.wav')
      separated   = []
      vocal_paths = []
      candidate   = VoiceReference::Candidate.new(audio: 'first.webm', text: 'Selected voice reference.')
      transcriber = double
      selector    = instance_double(VoiceReference::Selector)
      builder     = instance_double(VoiceReference::Builder)
      allow(VoiceSeparator).to receive(:separate) do |source, dir:|
        vocals     = File.join(dir, 'vocals.wav')
        non_vocals = File.join(dir, 'no-vocals.wav')
        File.write(vocals, source)
        File.write(non_vocals, 'music')
        separated << source
        vocal_paths << vocals
        VoiceSeparator::Stems.new(vocals: vocals, non_vocals: non_vocals)
      end
      allow(transcriber).to receive(:call) do |vocals, cache_key:, separate_voice:|
        expect(File.read(vocals)).to eq(cache_key)
        expect(separate_voice).to eq(false)
        {language: 'en', segments: []}
      end
      allow(VoiceReference::Selector).to receive(:new).with(language: 'en', strict: true).and_return(selector)
      allow(VoiceReference::Builder).to receive(:new).with(
        transcriber: transcriber, selector: selector, language: 'en', reference_filter: :raw
      ).and_return(builder)
      allow(builder).to receive(:build) do |audio_files:, source_files:, **|
        expect(source_files).to eq(sources)
        expect(audio_files.map { |path| File.read(path) }).to eq(sources)
        expect(audio_files).to all(satisfy { |path| File.exist?(path) })
        candidate
      end

      result = described_class.from_files(
        audio_files: sources, output: output, transcriber: transcriber
      )

      expect(result).to eq(candidate)
      expect(separated).to eq(%w[first.webm second.webm])
      expect(vocal_paths).to all(satisfy { |path| !File.exist?(path) })
    end
  end

  it 'cleans every prepared stem when selection fails' do
    paths = []
    allow(VoiceSeparator).to receive(:separate) do |_source, dir:|
      vocals     = File.join(dir, 'vocals.wav')
      non_vocals = File.join(dir, 'no-vocals.wav')
      File.write(vocals, 'voice')
      File.write(non_vocals, 'music')
      paths.concat([vocals, non_vocals])
      VoiceSeparator::Stems.new(vocals: vocals, non_vocals: non_vocals)
    end
    transcriber = double(call: {language: 'en', segments: []})
    allow(VoiceReference::Builder).to receive(:new).and_raise('selection failed')

    expect do
      described_class.from_files(audio_files: %w[first.webm second.webm], output: 'reference.wav', transcriber: transcriber)
    end.to raise_error('selection failed')
    expect(paths).to all(satisfy { |path| !File.exist?(path) })
  end
end
