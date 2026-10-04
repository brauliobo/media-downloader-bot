require 'rails_helper'

RSpec.describe Utils::Stats do
  it 'averages the two middle samples of an even median' do
    expect(described_class.median([4.0, 1.0, 2.0, 3.0])).to eq(2.5)
  end

  it 'takes the middle sample of an odd median' do
    expect(described_class.median([3.0, 1.0, 2.0])).to eq(2.0)
  end

  it 'rounds a percentile up to the sample covering the ratio' do
    expect(described_class.percentile([1.0, 2.0, 3.0, 4.0], 0.9)).to eq(4.0)
    expect(described_class.percentile([1.0, 2.0, 3.0, 4.0], 0.1)).to eq(1.0)
  end

  it 'weights larger samples through the quadratic mean' do
    expect(described_class.mean([1.0, 3.0])).to eq(2.0)
    expect(described_class.rms([3.0, 4.0])).to be_within(0.001).of(3.536)
  end

  it 'reduces an empty sample to zero' do
    expect([described_class.mean([]), described_class.rms([]), described_class.median([]),
            described_class.percentile([], 0.5)]).to all(eq(0.0))
  end
end
