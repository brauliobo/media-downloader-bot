require 'spec_helper'
require_relative '../../lib/utils/time_ranges'

RSpec.describe Utils::TimeRanges do
  it 'parses time intervals and merges overlapping or adjacent values' do
    ranges = described_class.parse('1:30-2:00.5,10-20,20-30,1:45-2:10', option: :cuts)

    expect(ranges.intervals).to eq([
      described_class::Interval.new(start: 10.0, finish: 30.0),
      described_class::Interval.new(start: 90.0, finish: 130.0),
    ])
    expect(ranges.total_duration).to eq(60.0)
  end

  it 'parses period and flexible clock endpoints' do
    ranges = described_class.parse('10s-20s,1m-2m,:30-45', option: :cuts)

    expect(ranges.intervals).to eq([
      described_class::Interval.new(start: 10.0, finish: 20.0),
      described_class::Interval.new(start: 30.0, finish: 45.0),
      described_class::Interval.new(start: 60.0, finish: 120.0),
    ])
  end

  it 'rejects points, descending intervals, and invalid clock components' do
    expect { described_class.parse('10', option: :cuts) }.to raise_error(ArgumentError, /invalid cuts option/)
    expect { described_class.parse('20-10', option: :cuts) }.to raise_error(ArgumentError, /invalid cuts option/)
    expect { described_class.parse('1:60-2:00', option: :cuts) }.to raise_error(ArgumentError, /invalid cuts option/)
  end

  it 'rejects intervals beyond the media duration and cuts that remove all media' do
    expect do
      described_class.parse('5-11', option: :silences).validate!(10)
    end.to raise_error(ArgumentError, /interval exceeds media duration/)

    expect do
      described_class.parse('0-10', option: :cuts).validate!(10, allow_entire: false)
    end.to raise_error(ArgumentError, /remove the entire media/)
  end
end
