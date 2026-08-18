require 'spec_helper'
require_relative '../../lib/utils/duration'

RSpec.describe Utils::Duration do
  def seconds(value) = described_class.parse(value)

  it 'parses numeric values and bare seconds' do
    expect(seconds(90)).to eq(90.0)
    expect(seconds('90')).to eq(90.0)
    expect(seconds('90.5')).to eq(90.5)
  end

  it 'parses flexible clock forms including skipped zeros' do
    expect(seconds('1:30')).to eq(90.0)
    expect(seconds('1:5')).to eq(65.0)
    expect(seconds('1:5:3')).to eq(3903.0)
    expect(seconds('0:0')).to eq(0.0)
    expect(seconds('1:30.5')).to eq(90.5)
    expect(seconds(':30')).to eq(30.0)
    expect(seconds('1:')).to eq(60.0)
    expect(seconds('1:30:')).to eq(5400.0)
    expect(seconds('1::')).to eq(3600.0)
    expect(seconds('1::5')).to eq(3605.0)
    expect(seconds('::45')).to eq(45.0)
    expect(seconds(':30.25')).to eq(30.25)
    expect(seconds('1:.5')).to eq(60.5)
    expect(seconds('01:30:00.123')).to eq(5400.123)
  end

  it 'parses compact period forms' do
    expect(seconds('90s')).to eq(90.0)
    expect(seconds('1.5m')).to eq(90.0)
    expect(seconds('1m30s')).to eq(90.0)
    expect(seconds('1h')).to eq(3600.0)
    expect(seconds('1h30m')).to eq(5400.0)
    expect(seconds('1h30m5s')).to eq(5405.0)
    expect(seconds('1h5s')).to eq(3605.0)
    expect(seconds('1H30M')).to eq(5400.0)
  end

  it 'rejects invalid clock and period values' do
    expect { seconds(':') }.to raise_error(ArgumentError)
    expect { seconds('::') }.to raise_error(ArgumentError)
    expect { seconds('1:60') }.to raise_error(ArgumentError)
    expect { seconds('1:60:00') }.to raise_error(ArgumentError)
    expect { seconds('1h30') }.to raise_error(ArgumentError)
    expect { seconds('') }.to raise_error(ArgumentError)
  end

  it 'raises option-aware errors and builds clip sections' do
    expect { described_class.parse!('1:60', option: :ss) }
      .to raise_error(ArgumentError, /invalid ss option/)

    cut = described_class.section(ss: '1m', t: '30s')
    expect(cut.start).to eq(60.0)
    expect(cut.duration).to eq(30.0)
    expect(cut.finish).to eq(90.0)

    expect { described_class.section(to: '2m', t: '30s') }
      .to raise_error(ArgumentError, /cannot combine with to/)
  end

  it 'supports instance arithmetic used by shorts' do
    expect(described_class.new('00:00:45') - described_class.new('00:00:01')).to eq(44.0)
  end
end
