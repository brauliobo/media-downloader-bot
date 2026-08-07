require 'spec_helper'

RSpec.describe Subtitler::VTT do
  def payloads(vtt)
    vtt.split(/\n\s*\n/).filter_map do |cue|
      lines = cue.lines.map(&:strip)
      timing = lines.find { |line| line.include?('-->') }
      next unless timing

      lines[(lines.index(timing) + 1)..].join(' ')
    end
  end

  it 'translates VTT by sentences and applies the shared length limit' do
    vtt = <<~VTT
      WEBVTT

      1
      00:00:00.000 --> 00:00:04.000
      Hello. <00:00:01.000>This is a second sentence.
    VTT
    long_translation = 'Esta é uma frase traduzida muito longa com conteúdo suficiente para ultrapassar o limite padrão de uma legenda e exigir divisão.'

    allow(::Translator).to receive(:translate).and_return(['Olá.', long_translation])

    translated = described_class.translate(vtt, from: 'en', to: 'pt')

    expect(::Translator).to have_received(:translate).with(
      ['Hello.', 'This is a second sentence.'],
      from: 'en',
      to:   'pt'
    )
    expect(payloads(translated)).to include('Olá.')
    expect(payloads(translated).join(' ')).to include(long_translation)
    expect(payloads(translated)).to all(have_attributes(length: be <= Subtitler::Translator::MAX_SUBTITLE_CHARS))
  end

  it 'keeps short translated sentences separate instead of prepending the next sentence' do
    vtt = <<~VTT
      WEBVTT

      00:00:00.000 --> 00:00:04.000
      Hello. This is another sentence.
    VTT

    allow(::Translator).to receive(:translate).and_return(['Olá.', 'Esta é outra frase.'])

    translated = described_class.translate(vtt, from: 'en', to: 'pt')

    expect(payloads(translated)).to eq(['Olá.', 'Esta é outra frase.'])
  end

  it 'translates cues that use minute-second timestamps' do
    vtt = <<~VTT
      WEBVTT

      00:00.240 --> 00:02.310
      Arthritis is getting worse.
    VTT

    allow(::Translator).to receive(:translate).and_return(['A artrite está piorando.'])

    translated = described_class.translate(vtt, from: 'en', to: 'pt')

    expect(translated).to include(
      "00:00:00.240 --> 00:00:02.310\nA artrite está piorando."
    )
  end

  it 'does not merge normalized cues from different speakers' do
    mash = SymMash.new(segments: [
      SymMash.new(text: 'Hello.', start: 0.0, end: 1.0, words: [], speaker_id: 0),
      SymMash.new(text: 'Goodbye.', start: 1.2, end: 2.0, words: [], speaker_id: 1),
    ])

    translated = described_class.build(mash)

    expect(payloads(translated)).to eq(['Hello.', 'Goodbye.'])
  end
end
