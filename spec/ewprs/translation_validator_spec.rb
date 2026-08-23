require 'spec_helper'
require_relative '../../lib/ewprs/translation_validator'

RSpec.describe Ewprs::TranslationValidator do
  subject(:validator) { described_class.new(source_language: 'en', target_language: 'pt') }

  it 'accepts a complete target-language translation' do
    expect(
      validator.valid?(
        source: 'The spiritual path is open to every human being.',
        translated: 'O caminho espiritual esta aberto a todo ser humano.'
      )
    ).to be(true)
  end

  it 'rejects unchanged source prose' do
    expect do
      validator.validate!(source: 'The spiritual path.', translated: 'The spiritual path.')
    end.to raise_error(described_class::Error, /left source prose unchanged/)

    expect do
      validator.validate!(
        source: 'Meditation transforms consciousness profoundly.',
        translated: 'Meditation transforms consciousness profoundly.'
      )
    end.to raise_error(described_class::Error, /left source prose unchanged/)

    expect do
      validator.validate!(source: 'O Soul Supreme!', translated: 'O Soul Supreme!')
    end.to raise_error(described_class::Error, /left source prose unchanged/)

    expect(
      validator.valid?(
        source: 'Bandhur path dhare shata ba&#x301;dha&#x301;te,',
        translated: 'Bandhur path dhare shata ba&#x301;dha&#x301;te,'
      )
    ).to be(true)

    german = described_class.new(source_language: 'en', target_language: 'de')
    expect(
      german.valid?(
        source: '<I>Ra&#x301;ma</I> &ndash; <I>ra&#x301;</I> plus <I>ma</I>.',
        translated: '<I>Ra&#x301;ma</I> &ndash; <I>ra&#x301;</I> plus <I>ma</I>.'
      )
    ).to be(true)
  end

  it 'rejects omitted source prose' do
    expect do
      validator.validate!(
        source: 'The Supreme alone knows its trade secrets.', translated: ''
      )
    end.to raise_error(described_class::Error, /omitted source prose/)
  end

  it 'rejects the frozen English idiom in the same way for non-English targets' do
    {
      'ja' => '同様に in the same way 喜ばれる。',
      'zh' => '同样 in the same way 喜悦。',
      'pt' => 'Do mesmo modo in the same way Deus se agrada.',
      'es' => 'Del mismo modo in the same way Dios se complace.',
      'fr' => 'De même in the same way Dieu est content.',
      'ar' => 'بالمثل in the same way يُسَر.',
      'de' => 'Ebenso in the same way ist Er erfreut.'
    }.each do |language, translated|
      validator = described_class.new(source_language: 'en', target_language: language)
      expect do
        validator.validate!(source: 'Similarly, Paramá Puruśa is pleased.', translated: translated)
      end.to raise_error(described_class::Error, /retained English phrase/)
    end

    japanese = described_class.new(source_language: 'en', target_language: 'ja')
    expect do
      japanese.validate!(
        source: 'This script is similar to Tibetan in some ways.',
        translated: 'この文字はチベット文字といくつかin the same way類似している。'
      )
    end.to raise_error(described_class::Error, /retained English phrase/)
  end

  it 'rejects leftover English discourse openers outside quotes' do
    japanese = described_class.new(source_language: 'en', target_language: 'ja')
    {
      'According to Maharsi Patañjali, the verse follows.' =>
        'According to Maharsi Patañjali、次の詩句が続く。',
      'Similarly, the suffix is added.' => 'Similarly, 接尾辞が付く。',
      'Therefore, the verse is cited.' => 'Therefore, その詩句が引用される。',
      'Likewise, the question is asked.' => 'Likewise, その問いが発せられる。',
      'Parama Purusa, however, is abhiista.' => 'パラマ・プルシャは however 願望の対象である。',
      'See the online additional information.' => '「Online additional information」を見る。'
    }.each do |source, translated|
      expect do
        japanese.validate!(source: source, translated: translated)
      end.to raise_error(described_class::Error, /retained English/)
    end
  end

  it 'keeps according to inside a quoted English title' do
    japanese = described_class.new(source_language: 'en', target_language: 'ja')

    expect(
      japanese.valid?(
        source: 'It also appeared as &ldquo;You Live According to God&#146;s Desire&rdquo;.',
        translated: '『You Live According to God&#146;s Desire』としても掲載されていた。'
      )
    ).to be(true)
  end

  it 'rejects leftover hyphenated English in Japanese except coined motion terms' do
    japanese = described_class.new(source_language: 'en', target_language: 'ja')

    expect do
      japanese.validate!(
        source: 'He is all-pervasive and self-illuminating.',
        translated: '彼はall-pervasiveでself-illuminatingである。'
      )
    end.to raise_error(described_class::Error, /retained English compound/)

    expect(
      japanese.valid?(
        source: 'This movement is extro-internal and intro-external.',
        translated: 'この動きはextro-internalかつintro-externalである。'
      )
    ).to be(true)
    expect(
      japanese.valid?(
        source: 'Hence, mrga-carma means the skin of any wild animal.',
        translated: 'したがって、mrga-carmaとはどんな野生動物の皮のことである。'
      )
    ).to be(true)
    expect(
      japanese.valid?(
        source: 'You can also remain idle &ndash; Pi-pu-phi-shu.',
        translated: '&ndash; Pi-pu-phi-shuのまま何もしなくてもよい。'
      )
    ).to be(true)

    chinese = described_class.new(source_language: 'en', target_language: 'zh')
    expect(
      chinese.valid?(
        source: '&ldquo;Pall-mall&rdquo; is pronounced pel-mel rather than pal-mal.',
        translated: '&ldquo;Pall-mall&rdquo; 的发音是 pel-mel,而不是 pal-mal。'
      )
    ).to be(true)
  end

  it 'rejects a retained English determiner in mixed Japanese' do
    japanese = described_class.new(source_language: 'en', target_language: 'ja')

    expect do
      japanese.validate!(
        source: 'The ahaḿkára affects human life.',
        translated: 'The ahaḿkáraは人間の生活に影響する。'
      )
    end.to raise_error(described_class::Error, /retained English determiner/)

    expect(
      japanese.valid?(
        source: 'It appeared as &ldquo;The Sound of God&rdquo;.',
        translated: '『The Sound of God』として現れた。'
      )
    ).to be(true)

    expect(
      japanese.valid?(
        source: 'but he is bhiis&#x301;an&#x301;a for all those objects.',
        translated: 'しかし、彼はすべての物体にとってbhiis&#x301;an&#x301;aなのである。'
      )
    ).to be(true)

    expect(
      japanese.valid?(
        source: 'Shrii Prabhat Ranjan Sarkar, The Liberation of Intellect: Neohumanism, 1982. &ndash;Trans.',
        translated: 'Shrii Prabhat Ranjan Sarkar, 『The Liberation of Intellect: Neohumanism』, 1982. &ndash;翻訳。'
      )
    ).to be(true)

    expect(
      japanese.valid?(
        source: 'the negation <I>a</I> is added before consonants and <I>an</I> before vowels.',
        translated: '否定辞の<I>a</I>は子音の前に、<I>an</I>は母音の前に置かれる。'
      )
    ).to be(true)

    chinese = described_class.new(source_language: 'en', target_language: 'zh')
    expect(
      chinese.valid?(
        source: 'they were specially known as chatra+an=chatra chat +rak=chatra.',
        translated: '他们被特别称为chatra+an=chatra，即chat +rak=chatra。'
      )
    ).to be(true)

    expect(
      japanese.valid?(
        source: 'hence __P0007__an__P0008__ must be used, not __P0001__a-rta__P0002__.',
        translated: 'よって__P0007__an__P0008__を使い、__P0001__a-rta__P0002__は使わない。'
      )
    ).to be(true)

    expect(
      japanese.valid?(
        source: 'the negation <I>a</I> is added before consonants and <I>an</I> before vowels.',
        translated: '否定辞の<I>a</I>は子音の前に、<I>an</I>は母音の前に置かれる。',
        protected_values: ['<I>', '</I>', '<I>a</I>']
      )
    ).to be(true)

    expect do
      japanese.validate!(
        source: 'Lord Shiva said, Brahmaeváham.',
        translated: 'Lord Shiva said, Brahmaeváham。救済は可能である。'
      )
    end.to raise_error(described_class::Error, /retained English determiner: said/)

    expect do
      japanese.validate!(
        source: 'yama and niyama are the first two limbs.',
        translated: 'yama and niyamaは最初の二支である。'
      )
    end.to raise_error(described_class::Error, /retained English coordinator/)

    chinese = described_class.new(source_language: 'en', target_language: 'zh')
    expect(
      chinese.valid?(
        source: 'They include (Kerala&#146;s Na&#x301;ya&#x301;r and Tamil nadu&#146;s Pilla&#x301;i groups).',
        translated: '它们包括(Kerala&#146;s Na&#x301;ya&#x301;r and Tamil nadu&#146;s Pilla&#x301;i groups)。'
      )
    ).to be(true)

    expect do
      japanese.validate!(
        source: 'The so-called ahiḿsá is hypocrisy.',
        translated: 'いわゆるso-called ahiḿsáは偽善である。'
      )
    end.to raise_error(described_class::Error, /retained English (?:determiner|compound): so-called/)
  end

  it 'rejects leaked English glosses from translator hints' do
    japanese = described_class.new(source_language: 'en', target_language: 'ja')
    {
      'The word is used literally here.' => 'ここはin the literal sense使われる。',
      'A, B and C respectively.' => 'A、B、Cはin the same orderである。',
      'This movement is extro-internal.' => 'この動きはfrom the external toward the internalである。',
      'Give a definition.' => 'それはstatement of meaningである。',
      'They were illiterate.' => '彼らはunable to read or writeであった。',
      'Some illustrative cases follow.' => 'いくつかserving as examplesがある。',
      'Oil from linseed.' => 'flax seedから油を取る。',
      'It spread through all of South East Asia.' => 'throughout Southeast Asiaに広がった。',
      'They inject fear into others.' => '彼らはintroduce or instillする。',
      'Those endeavours require strength.' => 'such effortsが必要である。',
      'All Rights Reserved' => 'All Rights Reserved'
    }.each do |source, translated|
      expect do
        japanese.validate!(source: source, translated: translated)
      end.to raise_error(described_class::Error, /retained English phrase/)
    end
  end

  it 'allows Chinese and Japanese to omit an English article before protected content' do
    %w[zh ja].each do |language|
      validator = described_class.new(source_language: 'en', target_language: language)

      expect(validator.valid?(source: 'The __P0001__', translated: '__P0001__')).to be(true)
      expect(validator.valid?(source: 'The', translated: '')).to be(false)
    end
  end

  it 'allows Arabic to omit an English article before protected content' do
    arabic = described_class.new(source_language: 'en', target_language: 'ar')

    expect(arabic.valid?(source: 'The __P0001__', translated: '__P0001__')).to be(true)
    expect(arabic.valid?(source: 'The', translated: '')).to be(false)
  end

  it 'does not reject unchanged formulas, citations, or scientific names' do
    expect(validator.valid?(source: 'A + u + m = Om.', translated: 'A + u + m = Om.')).to be(true)
    expect(
      validator.valid?(
        source: '(Ánanda Vacanámrtam I, 55)', translated: '(Ánanda Vacanámrtam I, 55)'
      )
    ).to be(true)
    expect(
      validator.valid?(source: 'Azadirachta indica A. juss.', translated: 'Azadirachta indica A. juss.')
    ).to be(true)
    expect(
      validator.valid?(
        source: 'Sa no buddhya shubhayá saḿyunaktu', translated: 'Sa no buddhya shubhayá saḿyunaktu'
      )
    ).to be(true)
  end

  it 'does not treat preserved formula operands as retained prose' do
    expect(
      validator.valid?(
        source: 'Specifically, ya = i + a, ra = r + a, la = lr + a, and va = o + a.',
        translated: 'Especificamente, ya = i + a, ra = r + a, la = lr + a, e va = o + a.'
      )
    ).to be(true)
  end

  it 'does not infer the source language from one coincidental dictionary word' do
    expect(
      validator.valid?(
        source: 'Sa no buddhya __P0002__ __P0001__.',
        translated: 'Sa no buddhya __P0002__ __P0001__.'
      )
    ).to be(true)
  end

  it 'allows an unchanged phrase made only of words shared with the target language' do
    spanish = described_class.new(source_language: 'en', target_language: 'es')

    expect(spanish.valid?(source: 'No, no.', translated: 'No, no.')).to be(true)
    expect(spanish.valid?(source: 'Oh, no, no, no.', translated: 'Oh, no, no, no.')).to be(true)
    expect(validator.valid?(source: 'No, no.', translated: 'No, no.')).to be(false)
  end

  it 'rejects a long source-language span prepended to a translation' do
    source = 'The human mind can move through the world in many different ways.'
    translated = "#{source} A mente humana pode se mover pelo mundo de muitas maneiras diferentes."

    expect do
      validator.validate!(source: source, translated: translated)
    end.to raise_error(described_class::Error, /retained a long source-language span/)
  end

  it 'rejects a retained five-word source-language span' do
    expect do
      validator.validate!(
        source: 'Spraying water like a fountain is also called __P0001__.',
        translated: 'Spraying water like a fountain é também chamado de __P0001__.'
      )
    end.to raise_error(described_class::Error, /retained a long source-language span/)
  end

  it 'allows retained prepositions around foreign examples and language names' do
    german = described_class.new(source_language: 'en', target_language: 'de')
    source = 'One example is __P0001__ in Angika, ham __P0002__ in Maethilii, __P0003__ in Bengali.'
    translated = 'Ein Beispiel ist __P0001__ in Angika, ham __P0002__ in Maethilii, __P0003__ in Bengali.'

    expect(german.valid?(source: source, translated: translated)).to be(true)
  end

  it 'allows a Latin protected term next to Chinese or Japanese prose without accepting Latin extensions' do
    {
      'zh' => ['mantra正在被诵读。', 'mantram正在被诵读。'],
      'ja' => ['mantraが唱えられている。', 'mantramが唱えられている。']
    }.each do |language, (valid, invalid)|
      validator = described_class.new(source_language: 'en', target_language: language)

      expect(
        validator.valid?(source: 'The mantra is recited.', translated: valid, protected_values: ['mantra'])
      ).to be(true)
      expect do
        validator.validate!(source: 'The mantra is recited.', translated: invalid, protected_values: ['mantra'])
      end.to raise_error(described_class::Error, /changed protected source text: mantra/)
    end
  end

  it 'allows a Latin protected term next to Arabic prose without accepting Latin extensions' do
    arabic = described_class.new(source_language: 'en', target_language: 'ar')
    source = 'The term is Kharos&#x301;t&#x301;hi.'
    translated = 'هذا هو وKharos&#x301;t&#x301;hi.'

    expect(
      arabic.valid?(
        source: source, translated: translated,
        protected_values: {'Kharos&#x301;t&#x301;hi' => 1}
      )
    ).to be(true)
    expect do
      arabic.validate!(
        source: source, translated: 'هذا هو وKharos&#x301;t&#x301;him.',
        protected_values: {'Kharos&#x301;t&#x301;hi' => 1}
      )
    end.to raise_error(described_class::Error, /changed protected source text: Kharośt́hi/)
  end

  it 'rejects changed line breaks' do
    expect do
      validator.validate!(source: "First line.\r\nSecond line.", translated: 'Primeira linha. Segunda linha.')
    end.to raise_error(described_class::Error, /changed line breaks/)
  end

  it 'rejects changed paired delimiters' do
    expect do
      validator.validate!(source: 'The mind (and body) move.', translated: 'A mente (e o corpo se movem.')
    end.to raise_error(described_class::Error, /changed paired delimiters/)

    expect do
      validator.validate!(source: 'The mind (and body) move.', translated: 'A mente )e o corpo( se movem.')
    end.to raise_error(described_class::Error, /changed paired delimiters/)

    expect do
      validator.validate!(source: 'The {mind (and body)} moves.', translated: 'A {mente) e o corpo (}se move.')
    end.to raise_error(described_class::Error, /changed paired delimiters/)
  end

  it 'allows intact balanced delimiter groups to follow CJK grammar' do
    {
      'zh' => '根据samskaras [心理动量]形成一种形态(心智体)',
      'ja' => 'samskaras [心的運動量]に従って形態(心的身体)を形成する'
    }.each do |language, translated|
      validator = described_class.new(source_language: 'en', target_language: language)

      expect(
        validator.valid?(
          source: 'a form (mental body) according to samskaras [mental momenta]',
          translated: translated
        )
      ).to be(true)
    end
  end

  it 'rejects newly escaped HTML character references' do
    expect do
      validator.validate!(
        source: 'The word &ldquo;dharma&rdquo; has a meaning.',
        translated: 'La palabra &ldquo;dharma&rdquo; tiene un significado&amp;rdquo.'
      )
    end.to raise_error(described_class::Error, /introduced an escaped HTML character reference/)

    expect(
      validator.valid?(
        source: 'The literal &amp;rdquo is shown.',
        translated: 'Se muestra el literal &amp;rdquo.'
      )
    ).to be(true)
  end

  it 'rejects changed or emptied smart quotes' do
    french = described_class.new(source_language: 'en', target_language: 'fr')

    expect do
      french.validate!(
        source: 'The word &ldquo;dharma&rdquo; has a meaning.',
        translated: 'Le mot &rdquo;dharma&ldquo; a un sens.'
      )
    end.to raise_error(described_class::Error, /reversed smart quotes/)

    expect do
      french.validate!(
        source: 'The word &ldquo;flow&rdquo; has a meaning.',
        translated: 'Le mot &ldquo;&rdquo; a un sens.'
      )
    end.to raise_error(described_class::Error, /introduced empty smart quotes/)

    expect(
      french.valid?(
        source: 'The word &ldquo;dharma&rdquo; means &ldquo;duty&rdquo;.',
        translated: 'Le mot &ldquo;dharma&rdquo; &ldquo;devoir&rdquo;.'
      )
    ).to be(true)

    german = described_class.new(source_language: 'en', target_language: 'de')
    expect(
      german.valid?(source: 'The word "dharma" has a meaning.', translated: 'Das Wort „dharma“ hat eine Bedeutung.')
    ).to be(true)
  end

  it 'rejects foreign-script characters introduced into Latin translations' do
    french = described_class.new(source_language: 'en', target_language: 'fr')

    expect do
      french.validate!(
        source: 'They direct their desires toward Him.',
        translated: 'Lorsque他们 orientent leurs désirs vers Lui.'
      )
    end.to raise_error(described_class::Error, /introduced foreign-script character/)

    expect(
      french.valid?(
        source: 'In Hindi, में indicates the locative case.',
        translated: 'En hindi, में indique le cas locatif.'
      )
    ).to be(true)

    german = described_class.new(source_language: 'en', target_language: 'de')
    expect do
      german.validate!(source: 'They direct their desires toward Him.', translated: 'Sie richten他们 Wünsche auf Ihn.')
    end.to raise_error(described_class::Error, /introduced foreign-script character/)
  end

  it 'rejects narrow high-confidence retained English words in French translations' do
    french = described_class.new(source_language: 'en', target_language: 'fr')

    expect do
      french.validate!(
        source: 'The liquid factor undergoes further crudification.',
        translated: 'Le facteur liquide subit une further crudification.'
      )
    end.to raise_error(described_class::Error, /retained source-language word: further/)

    expect(
      french.valid?(
        source: 'Published in The Great Universe.',
        translated: 'Publié dans The Great Universe.',
        protected_values: {'The Great Universe' => 1}
      )
    ).to be(true)
  end

  it 'accepts an exact phrase shared by English and German' do
    german = described_class.new(source_language: 'en', target_language: 'de')

    expect(german.valid?(source: 'negative evolution', translated: 'negative Evolution')).to be(true)
    expect(german.valid?(source: 'negative development', translated: 'negative Development')).to be(false)
  end

  it 'rejects high-confidence English residue in German translations' do
    german = described_class.new(source_language: 'en', target_language: 'de')

    expect do
      german.validate!(
        source: 'Limestone from Purulia can be used for making cement.',
        translated: 'Kalkstein aus Purulia can be used for making cement.'
      )
    end.to raise_error(described_class::Error, /retained source-language word: can/)

    expect do
      german.validate!(
        source: 'This body is derived from Bhuvar Loka of the cosmic mind.',
        translated: 'Dieser Körper stammt aus Bhuvar Loka of the cosmic mind.',
        protected_values: ['Bhuvar Loka']
      )
    end.to raise_error(described_class::Error, /retained English phrase/)

    expect do
      german.validate!(
        source: 'Similarly, the devotee serves all beings.',
        translated: 'Ebenso dient der Geweihte in the same way allen Wesen.'
      )
    end.to raise_error(described_class::Error, /retained English phrase/)

    expect do
      german.validate!(
        source: 'Similarly, the word means cotton.',
        translated: 'Similarly, das Wort means Baumwolle.'
      )
    end.to raise_error(described_class::Error, /retained source-language word/)

    expect do
      german.validate!(
        source: 'Avoid the Pátakiis-those who commit Pátaka.',
        translated: 'Meide die Pátakiis-those, die Pátaka begehen.'
      )
    end.to raise_error(described_class::Error, /retained source-language word: those/)

    expect(
      german.valid?(
        source: 'He bought it from a second-hand shop.',
        translated: 'Er kaufte es in einem Second-Hand-Laden.'
      )
    ).to be(true)

    expect(
      german.protected_source_fragment?(
        'A&#x301;nanda Mitra&#x301; A&#x301;c., and A&#x301;c.'
      )
    ).to be(false)

    expect do
      german.validate!(
        source: '__P0001__ and __P0002__ are coordinated.',
        translated: '__P0001__ and __P0002__ sind koordiniert.'
      )
    end.to raise_error(described_class::Error, /retained source-language word: and/)

    expect(
      german.valid?(
        source: '__P0001__ and __P0002__ are coordinated.',
        translated: '__P0001__ und __P0002__ sind koordiniert.'
      )
    ).to be(true)

    terms = ['Ks&#x301;ara', 'Aks&#x301;ara']
    expect do
      german.validate!(
        source: 'Ks&#x301;ara and Aks&#x301;ara',
        translated: 'Ks&#x301;ara and Aks&#x301;ara', protected_values: terms,
        protected_connectors: [['Ks&#x301;ara', '', 'and', 'Aks&#x301;ara']]
      )
    end.to raise_error(described_class::Error, /retained source-language word: and/)

    expect(
      german.valid?(
        source: 'Ks&#x301;ara and Aks&#x301;ara',
        translated: 'Ks&#x301;ara und Aks&#x301;ara', protected_values: terms,
        protected_connectors: [['Ks&#x301;ara', '', 'and', 'Aks&#x301;ara']]
      )
    ).to be(true)

    expect do
      german.validate!(
        source: '__P0001__., and __P0002__', translated: '__P0001__., and __P0002__'
      )
    end.to raise_error(described_class::Error, /retained source-language word: and/)

    expect(
      german.valid?(
        source: 'Yama and Niyama', translated: 'Yama and Niyama',
        protected_values: ['Yama and Niyama', 'Yama', 'Niyama']
      )
    ).to be(true)

    expect do
      german.validate!(
        source: 'Some examples are useful to illiterate villagers.',
        translated: 'Some examples are für illiterate Dorfbewohner nützlich.'
      )
    end.to raise_error(described_class::Error, /retained source-language word|example prose/)

    expect do
      german.validate!(
        source: 'avadhútikárespectively', translated: 'avadhútikárespectively'
      )
    end.to raise_error(described_class::Error, /retained source-language word: respectively/)

    {
      'Secondly, this is the next point.' => 'Secondly, dies ist der nächste Punkt.',
      'Hence Mádhava means Parama Puruśa.' => 'Hence Mádhava bedeutet Parama Puruśa.',
      'The history states that they descended from twelve sons.' =>
        'Die Geschichte states, dass sie descended von zwölf Söhnen.'
    }.each do |source, translated|
      expect do
        german.validate!(source: source, translated: translated)
      end.to raise_error(described_class::Error, /retained source-language word/)
    end

    expect do
      german.validate!(
        source: 'These practices come within the definition of avidya.',
        translated: 'Diese Praktiken fallen unter die definition of avidya.'
      )
    end.to raise_error(described_class::Error, /retained English definition prose/)

    expect(
      german.valid?(
        source: 'This is the definition of avidya.',
        translated: 'Dies ist die Definition von avidya.'
      )
    ).to be(true)
  end

  it 'ignores tracked English words that were not retained from the source' do
    german = described_class.new(source_language: 'en', target_language: 'de')

    expect(
      german.valid?(source: 'A heading.', translated: 'Eine Überschrift means Bedeutung.')
    ).to be(true)
  end

  it 'rejects escaped internal transport markers' do
    german = described_class.new(source_language: 'en', target_language: 'de')

    expect do
      german.validate!(
        source: 'The word &ldquo;good&rdquo;.',
        translated: 'Das Wort &lt;ewprs-quote-open id=&quot;1&quot;&gt;gut&lt;/ewprs-quote-close id=&quot;2&quot;/&gt;.'
      )
    end.to raise_error(described_class::Error, /internal transport marker/)

    expect do
      german.validate!(
        source: 'The word &ldquo;good&rdquo;.',
        translated: 'Das Wort &lt;span data=&quot;ewprs=&quot;11&quot;&gt;gut.'
      )
    end.to raise_error(described_class::Error, /internal transport marker/)
  end

  it 'rejects invalid unprotected French elisions' do
    french = described_class.new(source_language: 'en', target_language: 'fr')

    expect do
      french.validate!(source: 'When a person moves.', translated: 'Lorsque une personne se déplace.')
    end.to raise_error(described_class::Error, /invalid French elision/)

    expect(
      french.valid?(
        source: 'The French phrase &ldquo;de le&rdquo; is incorrect here.',
        translated: 'La locution française &ldquo;de le&rdquo; est incorrecte ici.',
        protected_values: {'&ldquo;de le&rdquo;' => 1}
      )
    ).to be(true)
  end

  it 'rejects whitespace that splits double editorial brackets' do
    expect do
      validator.validate!(
        source: 'In the days of Manu,[[note]] husbands would object.',
        translated: 'Nos tempos de Manu, [ [nota]] os maridos se oporiam.'
      )
    end.to raise_error(described_class::Error, /changed paired delimiters/)
  end

  it 'rejects newly duplicated sentences' do
    expect do
      validator.validate!(
        source: 'The mind is moving. The body is still.',
        translated: 'A mente esta se movendo. A mente esta se movendo. O corpo esta parado.'
      )
    end.to raise_error(described_class::Error, /duplicated a source sentence/)

    expect do
      validator.validate!(
        source: 'The mind is moving. The body is still. The soul is calm.',
        translated: 'A mente esta se movendo. O corpo esta parado. A mente esta se movendo.'
      )
    end.to raise_error(described_class::Error, /duplicated a source sentence/)
  end

  it 'allows source-authorized repeated sentences' do
    expect(
      validator.valid?(
        source: 'The mind is moving. The mind is moving.',
        translated: 'A mente esta se movendo. A mente esta se movendo.'
      )
    ).to be(true)
  end

  it 'rejects changed protected source text' do
    expect do
      validator.validate!(
        source: 'The term <i>A&#x301;nanda karma</i> is used.',
        translated: 'O termo <i>Ananda carma</i> e usado.',
        protected_values: ['<i>A&#x301;nanda karma</i>']
      )
    end.to raise_error(described_class::Error, /changed protected source text/)
  end

  it 'does not count a protected word inside a target-language inflection' do
    expect(
      validator.valid?(
        source: 'The mantra is one of many chants.',
        translated: 'O mantra e um dos muitos mantras.',
        protected_values: {'mantra' => 1}
      )
    ).to be(true)
  end

  it 'excludes exact protected publication titles from translation progress' do
    titles = 'Cosmic Society, Bodhi Kalpa, Education and Culture'

    expect(
      validator.valid?(
        source: "Previously printed in the magazines: #{titles} and others.",
        translated: "Anteriormente publicado nas revistas: #{titles} e outras.",
        protected_values: {titles => 1}
      )
    ).to be(true)
  end

  it 'still rejects source prose retained outside protected publication titles' do
    titles = 'Cosmic Society, Bodhi Kalpa, Education and Culture'

    expect do
      validator.validate!(
        source: "The title was printed in the magazines: #{titles} and others.",
        translated: "The title was printed in the magazines: #{titles} e outras.",
        protected_values: {titles => 1}
      )
    end.to raise_error(described_class::Error, /retained a long source-language span/)
  end

  it 'identifies a marked non-source-language passage' do
    expect(
      validator.protected_source_fragment?(
        'Toma&#x301;r tare ma&#x301;latii ma&#x301;la&#x301; toma&#x301;r tare sura sa&#x301;dha&#x301;.'
      )
    ).to be(true)
    expect(validator.protected_source_fragment?('Sa no buddhya shubhayá saḿyunaktu')).to be(true)
    expect(
      validator.protected_source_fragment?('Similarly, ni &ndash; var + anat́ = nivárańa.')
    ).to be(false)
    expect(
      validator.protected_source_fragment?(
        'Parama Purusa, however, is abhiista, all-pervasive, self-illuminating.'
      )
    ).to be(false)
  end

  it 'does not protect English prose that contains marked source-language terms' do
    arabic = described_class.new(source_language: 'en', target_language: 'ar')

    expect(
      arabic.protected_source_fragment?(
        'And the Tibeto-Chinese languages include Ladhakii, Kinnarii, Kirátii, Lepcá, Yiáru, ' \
        'Gáro, Khaśiya, Mizo and Newari.'
      )
    ).to be(false)
    expect(
      arabic.protected_source_fragment?(
        'These propensities are dharma, artha, káma, mokśa, avajiṋá, múrcchá, and prashraya.'
      )
    ).to be(false)
  end

  it 'recognizes source-language connectors in mixed linguistic examples' do
    arabic = described_class.new(source_language: 'en', target_language: 'ar')

    [
      'The word &ldquo;Tamil&rdquo; comes from the word drávid́ &ndash; drávid́ &rarr; drámid́ &rarr; drámil &rarr; támil.',
      'After Bhúr bhuvah svah another oṋm.',
      'Agraháyańa, Paośa, Mágha, Phálguna &ndash; plant wheat with big lentils, big peas or red mustard.',
      'T́a, t́ha, d́a, d́ha, ńa, and śa are cerebral letters.',
      'PARÁ SHÁNTI. Absolute peace, supreme beatitude.',
      'BÁBÁ. Affectionate name for Shrii Shrii Ánandamúrti.',
      'ANANDA MARGA. Path of divine bliss; Ánanda Márga Pracáraka Saḿgha.',
      'GAOŔIIYA VAEŚŃAVA DHARMA. The Bengalee Vaishnavite religion.',
      'BAODDHA VIJIŃÁNAVÁDA. School of Buddhist Maháyáńa philosophy.',
      'Remembering Parama Puruśa is dhyána.',
      'Rukmińii was Krśńa’s wife.',
      'Kaśt́a cannot be spelled kast́a.',
      'Margaret Áhladii Dásii was overjoyed.'
    ].each do |source|
      expect(arabic.protected_source_fragment?(source)).to be(false), source
    end

    expect(
      arabic.valid?(
        source: '__P0001__ remains the exclusive witness.',
        translated: '__P0001__ remains the exclusive witness.'
      )
    ).to be(false)

    expect(arabic.protected_source_fragment?("So'pi pápavinirmukto mám eva prapadyate")).to be(true)
  end

  it 'does not protect mixed foreign text containing source-language prose anchors' do
    german = described_class.new(source_language: 'en', target_language: 'de')

    expect(
      german.protected_source_fragment?(
        'Kr + pás = karpás. Karpás means &ldquo;cotton&rdquo;.'
      )
    ).to be(false)
    expect(
      german.protected_source_fragment?('Pápa plus Pratyaváya is Pátaka.')
    ).to be(false)
    expect(german.protected_inline_fragment?('so-called ahiḿsá')).to be(false)
  end

  it 'identifies a foreign inline phrase without treating source prose as foreign' do
    expect(validator.protected_inline_fragment?('praka&#x301;ram&#x301; karoti iti')).to be(true)
    expect(validator.protected_inline_fragment?('canda&#x301;ma&#x301;ma')).to be(true)
    expect(validator.protected_inline_fragment?('a,')).to be(true)
    expect(validator.protected_inline_fragment?('bauls')).to be(false)
    expect(validator.protected_inline_fragment?('the Supreme Entity')).to be(false)
  end
end
