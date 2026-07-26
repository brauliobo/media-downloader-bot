require 'spec_helper'
require_relative '../../lib/ewprs/sentence_splitter'

RSpec.describe Ewprs::SentenceSplitter do
  it 'finds sentence boundaries through transparent markup tokens' do
    text = 'First sentence.__P0001__ __P0002__Second sentence!'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq(
      ['First sentence.__P0001__', '__P0002__Second sentence!']
    )
  end

  it 'starts a new sentence before opening editorial brackets' do
    text = 'First sentence. [[And the]] second sentence.'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq(
      ['First sentence.', '[[And the]] second sentence.']
    )
  end

  it 'starts a new sentence before opening quote entities' do
    text = 'First reference. &ldquo;Second Reference&rdquo; follows.'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq(
      ['First reference.', '&ldquo;Second Reference&rdquo; follows.']
    )
  end

  it 'starts a new sentence before literal opening quotes' do
    text = 'First sentence. “Second sentence.”'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq(
      ['First sentence.', '“Second sentence.”']
    )
  end

  it 'splits excerpts after an HTML omission marker' do
    text = 'First excerpt.&#8230; to [[vest]] an incompetent person with power.'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq(
      ['First excerpt.&#8230;', 'to [[vest]] an incompetent person with power.']
    )
  end

  it 'splits oversized sentences at clause boundaries' do
    text = 'Alpha beta gamma; delta epsilon zeta, eta theta iota.'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 20)).to eq(
      ['Alpha beta gamma;', 'delta epsilon zeta,', 'eta theta iota.']
    )
  end

  it 'splits contrast clauses without changing their punctuation' do
    first = "People fear #{'many objects, ' * 20}and many people,"
    second = "but he is fearsome for #{'all those objects, ' * 10}people, etc."
    text = "#{first} #{second}"

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq(
      [first, second]
    )
  end

  it 'keeps ordinary contrast prose in one unit' do
    text = 'People fear __P0001__ objects, but he protects them.'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq([text])
  end
end
