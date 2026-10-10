require 'rails_helper'

RSpec.describe Ewprs::TranslationClauses do
  it 'splits contrast clauses without changing their punctuation' do
    first = "People fear #{'many objects, ' * 20}and many people,"
    second = "but he is fearsome for #{'all those objects, ' * 10}people, etc."
    text = "#{first} #{second}"

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq(
      [first, second]
    )
  end

  it 'splits compact comma-dense contrast clauses' do
    first = 'People fear many objects, many things, many entities, and many people,'
    second = 'but he is fearsome for all those objects, people, etc.'

    expect(described_class.split("#{first} #{second}", boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq(
      [first, second]
    )
  end

  it 'keeps ordinary contrast prose in one unit' do
    text = 'People fear __P0001__ objects, but he protects them.'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq([text])
  end

  it 'splits dense paired coordination into comma clauses' do
    text = 'They used both __P0001__, in the manner of __P0002__, and __P0003__, in the manner of __P0004__.'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq(
      [
        'They used both __P0001__,', 'in the manner of __P0002__,',
        'and __P0003__,', 'in the manner of __P0004__.'
      ]
    )
  end
end
