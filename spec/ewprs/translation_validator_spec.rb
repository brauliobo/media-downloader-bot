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
  end

  it 'rejects omitted source prose' do
    expect do
      validator.validate!(
        source: 'The Supreme alone knows its trade secrets.', translated: ''
      )
    end.to raise_error(described_class::Error, /omitted source prose/)
  end

  it 'allows Chinese to omit an English article before protected content' do
    chinese = described_class.new(source_language: 'en', target_language: 'zh')

    expect(chinese.valid?(source: 'The __P0001__', translated: '__P0001__')).to be(true)
    expect(chinese.valid?(source: 'The', translated: '')).to be(false)
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

  it 'allows a Latin protected term next to Chinese prose without accepting Latin extensions' do
    chinese = described_class.new(source_language: 'en', target_language: 'zh')

    expect(
      chinese.valid?(
        source: 'The mantra is recited.', translated: 'mantra正在被诵读。', protected_values: ['mantra']
      )
    ).to be(true)
    expect do
      chinese.validate!(
        source: 'The mantra is recited.', translated: 'mantram正在被诵读。', protected_values: ['mantra']
      )
    end.to raise_error(described_class::Error, /changed protected source text: mantra/)
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

  it 'allows intact balanced delimiter groups to follow target grammar' do
    chinese = described_class.new(source_language: 'en', target_language: 'zh')

    expect(
      chinese.valid?(
        source: 'a form (mental body) according to samskaras [mental momenta]',
        translated: '根据samskaras [心理动量]形成一种形态(心智体)'
      )
    ).to be(true)
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
