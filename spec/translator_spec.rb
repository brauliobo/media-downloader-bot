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
      markers = lines.join.scan(/__[A-Za-z0-9_]+_\d+__/)
      expect(markers.size).to eq(2)
      expect(markers.uniq.size).to eq(2)
      ['Olá ' + markers[0] + 'mundo', 'Novamente ' + markers[1] + 'hoje.']
    end

    translated = described_class.translate_srt(srt, from: 'en', to: 'pt')

    expect(translated).to include("Olá <00:00:02,000>mundo\nNovamente <00:00:03.000>hoje.")
    expect(translated).to include('00:00:01,000 --> 00:00:04,000')
  end

  it 'fails when a backend removes, duplicates, or reorders placeholders' do
    [:missing, :duplicate, :reordered].each do |corruption|
      allow(described_class).to receive(:translate) do |lines, **|
        markers = lines.join.scan(/__[A-Za-z0-9_]+_\d+__/)
        case corruption
        when :missing then ['Hello world', lines[1]]
        when :duplicate then [lines[0].sub(markers[0], markers[0] * 2), lines[1]]
        when :reordered then [lines[0].sub(markers[0], markers[1]), lines[1].sub(markers[1], markers[0])]
        end
      end

      expect { described_class.translate_srt(srt, from: 'en', to: 'pt') }
        .to raise_error(RuntimeError, /corrupted inline timestamps/)
    end
  end

  it 'fails clearly when a backend returns too few or too many lines' do
    [
      ['Only one'],
      ['First', 'Second', 'Unexpected third'],
    ].each do |results|
      allow(described_class).to receive(:translate).and_return(results)

      expect { described_class.translate_srt(srt, from: 'en', to: 'pt') }
        .to raise_error(RuntimeError, 'SRT translation result count mismatch: expected 2, got ' + results.length.to_s)
    end
  end

  it 'translates ordinary SRT without adding markers' do
    plain = "1\n00:00:01,000 --> 00:00:02,000\nHello world\n"
    expect(described_class).to receive(:translate).with(['Hello world'], from: 'en', to: 'pt').and_return(['Olá mundo'])

    translated = described_class.translate_srt(plain, from: 'en', to: 'pt')

    expect(translated).to include('Olá mundo')
    expect(translated).not_to include('__T', '<00:00:')
  end

  it 'treats the old placeholder namespace as ordinary prose' do
    source = "1\n00:00:01,000 --> 00:00:02,000\nLiteral __T0000__ <00:00:01,500>text\n"
    expect(described_class).to receive(:translate) do |lines, **|
      expect(lines.first).to include('__T0000__')
      [lines.first.sub('Literal', 'Literal traduzido')]
    end

    expect(described_class.translate_srt(source, from: 'en', to: 'pt'))
      .to include('Literal traduzido __T0000__ <00:00:01,500>text')
  end

  it 'uses collision-free unbounded placeholder indexes' do
    lines = [(0..10_000).map { |index| "<00:00:01,000>w#{index}" }.join]

    protected, replacements, marker_pattern = described_class.send(:protect_srt_timestamps, lines)

    markers = protected.first.scan(marker_pattern)
    expect(markers.size).to eq(10_001)
    expect(markers.last).to end_with('_10000__')
    expect(replacements.first.last.first).to eq(markers.last)
  end
end
