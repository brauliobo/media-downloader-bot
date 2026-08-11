require 'spec_helper'
require_relative '../../lib/utils/range_list'

RSpec.describe Utils::RangeList do
  it 'parses comma-separated points and ranges through the supplied value parser' do
    ranges = described_class.parse('6,1,3-5', option: :pages) { |value| Integer(value, 10) }

    expect(ranges.map { |range| [range.first, range.last] }).to eq([[6, 6], [1, 1], [3, 5]])
  end

  it 'can require every value to be a range' do
    expect do
      described_class.parse('1', option: :cuts, allow_single: false) { |value| Integer(value, 10) }
    end.to raise_error(ArgumentError, /invalid cuts option/)
  end
end
