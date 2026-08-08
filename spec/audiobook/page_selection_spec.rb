require 'spec_helper'
require_relative '../../lib/audiobook/page_selection'

RSpec.describe Audiobook::PageSelection do
  it 'expands ranges, removes duplicates, and sorts pages' do
    expect(described_class.parse('6,1,3-6,3')).to eq([1, 3, 4, 5, 6])
  end

  it 'rejects invalid and descending ranges' do
    expect { described_class.parse('1,6-3') }.to raise_error(ArgumentError, /invalid pages option/)
    expect { described_class.parse('0') }.to raise_error(ArgumentError, /invalid pages option/)
    expect { described_class.parse('1,') }.to raise_error(ArgumentError, /invalid pages option/)
  end
end
