require 'rails_helper'

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

  it 'starts a new sentence before a standalone parenthetical' do
    text = 'First sentence. (__P0001__Editorial sentence.__P0002__) Next sentence.'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq(
      ['First sentence.', '(__P0001__Editorial sentence.__P0002__) Next sentence.']
    )
  end

  it 'splits CJK sentences without requiring spaces or uppercase letters' do
    text = '第一句。 第二句！第三句？“第四句。”'

    expect(described_class.split(text, max_chars: 800)).to eq(
      ['第一句。', '第二句！', '第三句？', '“第四句。”']
    )
  end

  it 'keeps grouped numeric values in the same sentence' do
    text = 'There were 1.000 People and 3.14 Units. Then they left.'

    expect(described_class.split(text, max_chars: 800)).to eq(
      ['There were 1.000 People and 3.14 Units.', 'Then they left.']
    )
  end

  it 'keeps an honorific and name in the same sentence' do
    text = 'Hypnotism was used to cure disease by Dr. James Braid. This method spread.'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq(
      ['Hypnotism was used to cure disease by Dr. James Braid.', 'This method spread.']
    )
  end

  it 'keeps a single-letter initial attached to the name that follows' do
    expect(described_class.split('Published by Roger L. Cole in Hollister. Then it moved.', max_chars: 800)).to eq(
      ['Published by Roger L. Cole in Hollister.', 'Then it moved.']
    )
    expect(described_class.split('back under U. S. Treasury control. It worked.', max_chars: 800)).to eq(
      ['back under U. S. Treasury control.', 'It worked.']
    )
  end

  it 'keeps a roman numeral attached to the title it numbers' do
    expect(described_class.split('Chapter II. The Seven Hermetic Principles.', max_chars: 800)).to eq(
      ['Chapter II. The Seven Hermetic Principles.']
    )
  end

  it 'starts a new sentence at an enumerator that follows a full stop' do
    expect(described_class.split('Espécie de magia baseada nos espíritos celestes. 2. Arte de fazer milagres.', max_chars: 800)).to eq(
      ['Espécie de magia baseada nos espíritos celestes.', '2. Arte de fazer milagres.']
    )
    expect(described_class.split('Fresh organic beef liver and red meat. e. Raw honey', max_chars: 800)).to eq(
      ['Fresh organic beef liver and red meat.', 'e. Raw honey']
    )
  end

  it 'keeps a run of footnote markers with the sentence they close' do
    expect(described_class.split('bem como por emoções stressantes.17,18 O CRF regula a ansiedade.', max_chars: 800)).to eq(
      ['bem como por emoções stressantes.17,18', 'O CRF regula a ansiedade.']
    )
  end

  it 'packs clause pieces of an oversized sentence back up to the limit' do
    text = 'Abscesos dentales, acidez estomacal, acné, algunas diabetes, algunos casos de enfermedad celíaca, artritis.'

    expect(described_class.split(text, max_chars: 40)).to eq(
      ['Abscesos dentales, acidez estomacal,', 'acné, algunas diabetes,', 'algunos casos de enfermedad celíaca,', 'artritis.']
    )
  end

  it 'keeps a leading section number attached to its heading' do
    expect(described_class.split('1. O Ciclo das Políticas Públicas', max_chars: 800)).to eq(
      ['1. O Ciclo das Políticas Públicas']
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

  it 'hard-splits oversized CJK text without whitespace boundaries' do
    text = '这是一个没有空格或标点的中文句子'

    expect(described_class.split(text, max_chars: 6)).to eq(
      ['这是一个没有', '空格或标点的', '中文句子']
    )
  end

  it 'splits contrast clauses without changing their punctuation' do
    first = "People fear #{'many objects, ' * 20}and many people,"
    second = "but he is fearsome for #{'all those objects, ' * 10}people, etc."
    text = "#{first} #{second}"

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800, clauses: true)).to eq(
      [first, second]
    )
  end

  it 'keeps contrast clauses together when narrating instead of unitizing' do
    first = "People fear #{'many objects, ' * 20}and many people,"
    second = "but he is fearsome for #{'all those objects, ' * 10}people, etc."

    expect(described_class.split("#{first} #{second}", boundary_tokens: /__P\d{4}__/, max_chars: 8_000))
      .to eq(["#{first} #{second}"])
  end

  it 'splits compact comma-dense contrast clauses' do
    first = 'People fear many objects, many things, many entities, and many people,'
    second = 'but he is fearsome for all those objects, people, etc.'

    expect(described_class.split("#{first} #{second}", boundary_tokens: /__P\d{4}__/, max_chars: 800, clauses: true)).to eq(
      [first, second]
    )
  end

  it 'keeps ordinary contrast prose in one unit' do
    text = 'People fear __P0001__ objects, but he protects them.'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800)).to eq([text])
  end

  it 'splits dense paired coordination into comma clauses' do
    text = 'They used both __P0001__, in the manner of __P0002__, and __P0003__, in the manner of __P0004__.'

    expect(described_class.split(text, boundary_tokens: /__P\d{4}__/, max_chars: 800, clauses: true)).to eq(
      [
        'They used both __P0001__,', 'in the manner of __P0002__,',
        'and __P0003__,', 'in the manner of __P0004__.'
      ]
    )
  end
end
