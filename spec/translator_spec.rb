require 'spec_helper'

RSpec.describe Translator do
  let(:srt) do
    <<~SRT
      1
      00:00:01,000 --> 00:00:04,000
      Hello <00:00:02,000>world
      Again <00:00:03.000>today.
    SRT
  end

  it 'protects and exactly restores multiple inline timestamps across lines' do
    expect(described_class).to receive(:translate) do |lines, **|
      expect(lines).to eq(['Hello __T0000__world', 'Again __T0001__today.'])
      ['Olá __T0000__mundo', 'Novamente __T0001__hoje.']
    end

    translated = described_class.translate_srt(srt, from: 'en', to: 'pt')

    expect(translated).to include("Olá <00:00:02,000>mundo\nNovamente <00:00:03.000>hoje.")
    expect(translated).to include('00:00:01,000 --> 00:00:04,000')
  end

  it 'fails when a backend removes, duplicates, or reorders placeholders' do
    [
      ['Hello world', 'Again __T0001__today.'],
      ['Hello __T0000____T0000__world', 'Again __T0001__today.'],
      ['Hello __T0001__world', 'Again __T0000__today.'],
    ].each do |output|
      allow(described_class).to receive(:translate).and_return(output)

      expect { described_class.translate_srt(srt, from: 'en', to: 'pt') }
        .to raise_error(RuntimeError, /corrupted inline timestamps/)
    end
  end

  it 'translates ordinary SRT without adding markers' do
    plain = "1\n00:00:01,000 --> 00:00:02,000\nHello world\n"
    expect(described_class).to receive(:translate).with(['Hello world'], from: 'en', to: 'pt').and_return(['Olá mundo'])

    translated = described_class.translate_srt(plain, from: 'en', to: 'pt')

    expect(translated).to include('Olá mundo')
    expect(translated).not_to include('__T', '<00:00:')
  end
end
