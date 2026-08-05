require 'spec_helper'
require_relative '../../lib/ewprs'

RSpec.describe Ewprs::TranslationBatch do
  class FakeMarkupTranslator
    attr_reader :calls, :jobs, :repair_calls

    def initialize(jobs: 1, &transform)
      @jobs = jobs
      @transform = transform || lambda do |text|
        text.gsub('English', 'Português').gsub('Translate me', 'Traduza-me').gsub(/\band\b/, 'e')
      end
      @calls = []
      @repair_calls = []
    end

    def translate_markup(texts, from: 'en', to:)
      @calls.concat(texts)
      texts.map(&@transform)
    end

    def repair_markup(source, invalid:, issue:, tokens:, from: 'en', to:)
      @repair_calls << {
        source: source, invalid: invalid, issue: issue, tokens: tokens, from: from, to: to
      }
      @transform.call(source)
    end

    def translate_preserving_placeholders(text, values: {}, from: 'en', to:)
      @transform.call(text)
    end

    def translate_preserving_placeholder_order(text, from: 'en', to:)
      @transform.call(text)
    end

    def translate_preserving_editorial_tags(text, from: 'en', to:)
      @transform.call(text)
    end
  end

  let(:root) { Dir.mktmpdir('ewprs-translation-') }
  let(:cache) { File.join(root, 'cache.jsonl') }
  let(:translator) { FakeMarkupTranslator.new }
  let(:batch) do
    described_class.new(root: root, cache: cache, translator: translator, stdout: StringIO.new)
  end
  let(:source) do
    <<~HTML.gsub("\n", "\r\n")
      <html><head><title>English &ndash; title</title><style>.English { color: red; }</style></head><body>
      <div class=discourse_title>English title</div>
      <p class="Para_Notes">English note with <i>Brahma</i>.</p>
      <p class="Para_Major_Heading"><!-- block a=1 type=paragraph -->English major heading<!-- /block --></p>
      <p class="Para_Minor_Heading"><!-- block a=2 type=paragraph -->English minor heading<!-- /block --></p>
      <p class="Para_Indent"><!-- block a=3 type=paragraph -->Translate me with A&#x301;nanda and <b>English markup</b>.<!-- /block --></p>
      <p class="Para_Indent"><!-- block a=3b type=paragraph -->English before footnote.<!-- fn --><a name="Ref.fn2"></a><sup>(<b><a href="#fn2">2</a></b>)</sup><!-- /fn --> English after footnote.<!-- /block --></p>
      <p class="Para_Indent"><!-- block a=3c type=paragraph -->English table:<table><tr><td>English first cell.</td><td>English second cell.</td></tr></table><!-- /block --></p>
      <p class="plain"><!-- block a=4 type=paragraph -->English plain sentence. <b>English next sentence.</b><!-- /block --></p>
      <p class="plain"><!-- block a=4b type=paragraph -->Toma&#x301;r tare ma&#x301;latii ma&#x301;la&#x301;<br>Toma&#x301;r tare sura sa&#x301;dha&#x301;.<!-- /block --></p>
      <p class="plain"><!-- block a=4c type=paragraph -->English poetic rendering first line.<br>English poetic rendering second line.<!-- /block --></p>
      <p class="plain"><!-- block a=4d type=paragraph -->English introduction, Eso A&#x301;y bet&#x301;a&#x301; toke dekhe noba. [&ldquo;English rendering! English second rendering!&rdquo;] English after.<!-- /block --></p>
      <p class="plain"><!-- block a=4e type=paragraph -->English about <i>A&#x301;nanda karma</i> [English bliss] and madhyama [English middle].<!-- /block --></p>
      <p class="Para_Sloka"><!-- block a=5 type=paragraph -->Ayama&#x301;rambhah shubha&#x301;ya bhavatu.<br>Dharmo raksati raksitah.<!-- /block --></p>
      <p class="Para_Translation_Eds"><!-- block a=6 type=paragraph -->[English translation.]<!-- /block --></p>
      <p class="Para_Citation"><!-- block a=7 type=paragraph -->English citation<!-- /block --></p>
      <p class="Para_Quote"><!-- block a=8 type=paragraph -->English quotation<!-- /block --></p>
      <center><!-- block a=9 type=paragraph -->English centered text<!-- /block --></center>
      <p class="Para_Footnote"><a name=fn1></a>English footnote about Prakrti.</p>
      <p class="Para_Indent"><!-- block a=10 type=paragraph -->English before <span class=Bengali>&#x09A7;&#x09B0;&#x09CD;&#x09AE;</span> English after.<!-- /block --></p>
      </body></html>
    HTML
  end

  before do
    FileUtils.mkdir_p(File.join(root, 'HTML/Discourses'))
    FileUtils.mkdir_p(File.join(root, 'HTML/Books'))
    FileUtils.mkdir_p(File.join(root, 'HTML/Info'))
    File.write(
      File.join(root, 'HTML/Info/MasterGlossary.html'),
      '<html><body><p><b>Brahma</b> Supreme Entity</p><p><b>Prakrti</b> Operative Principle</p>' \
      '<p><b>Sat</b> unchangeable entity</p><p><b>Vayus</b> vital airs</p></body></html>'
    )
    File.binwrite(File.join(root, 'HTML/Discourses/Complete.html'), source)
  end

  after { FileUtils.remove_entry(root) if Dir.exist?(root) }

  it 'covers every known content class in the fixture' do
    result = batch.plan

    expect(result[:classes]).to eq(described_class::CONTENT_CLASSES.to_h { |name| [name, 1] })
    expect(result[:protected_elements]).to eq(7)
  end

  it 'unitizes documents without protected content' do
    template = batch.send(:unitize, '<html><body><p>English sentence.</p></body></html>')

    expect(template).to match(/⟦U[0-9a-f]{64}⟧/)
  end

  it 'normalizes duplicate dashes after nested units are composed' do
    key = 'a' * 64
    document = described_class::Document.new(template: "Text &ndash; ⟦U#{key}⟧")

    expect(batch.send(:render, document, key => '– continuation')).to eq('Text &ndash; continuation')
  end

  it 'translates English connectors in Sanskrit-heavy titles' do
    title = 'Abhedajin&#x32D;a&#x301;na and Daeshika Vyavadha&#x301;na Vilopa'
    source = '<div class=discourse_box_title_ref><!-- block a=title type=title -->' \
             "#{title}<!-- /block --></div><div class=discourse_title>#{title}</div>"
    template = batch.send(:unitize, source)
    translations = batch.send(:translate_units)
    rendered = batch.send(:render, described_class::Document.new(template: template), translations)

    expect(rendered.scan('Abhedajin&#x32D;a&#x301;na e Daeshika Vyavadha&#x301;na Vilopa').size).to eq(2)
  end

  it 'does not protect English prose inside a marked Sanskrit definition' do
    unit = batch.send(
      :prepare_unit, 'marked-definition-prose',
      'pa&#x301;na&#x301; means sarvat [a sweet drink made from syrup].'
    )

    expect(unit.prepared).to include('means')
    expect(unit.tokens.values).not_to include(a_string_matching(/means/))
  end

  it 'normalizes deterministic French elisions before validation' do
    french = described_class.new(root: root, target: 'fr', cache: cache, translator: translator, stdout: StringIO.new)

    expect(
      french.send(
        :normalize_target_language,
        'Lorsque Un être contemple Ce Univers, lorsque une idée surgit, lorsque他们 arrivent？ ' \
        'Ce Nucleus subit une further grossification vers la salvation. ' \
        'The Supreme Entity est un flux continu de cognition. Le terme anglais est salvation.'
      )
    ).to eq(
      'Lorsqu’un être contemple Cet univers, lorsqu’une idée surgit, lorsqu’ils arrivent? ' \
      'Ce noyau subit une grossification supplémentaire vers le salut. ' \
      'L’Entité suprême est un flux continu de cognition. Le terme anglais est salvation.'
    )
  end

  it 'normalizes fullwidth punctuation before target-script validation' do
    expect(batch.send(:normalize_target_language, 'Beispiel，Fortsetzung？')).to eq('Beispiel,Fortsetzung?')

    unit = described_class::Unit.new(
      key: 'fullwidth-punctuation', source: 'Example, continuation?', prepared: 'Example, continuation?',
      tokens: {}, leading: '', trailing: ''
    )
    expect(batch.send(:validate_restored_translation!, unit, 'Beispiel， Fortsetzung？')).to eq(
      'Beispiel, Fortsetzung?'
    )
  end

  it 'normalizes deterministic mixed-language French residues' do
    french = described_class.new(root: root, target: 'fr', cache: cache, translator: translator, stdout: StringIO.new)
    residues = 'Videha liina are caused by ones bhavapratyaya. ' \
               'Sa&#x301;hitya means all those manifestations. ' \
               'Ma&#x301;gadhii language of that time. ' \
               'Vargiiya Ba and Antahstha Va to Osadhipati. ' \
               'Human Life and Its goal has been formed by adding the Farsi suffix. ' \
               'all the three types of vrttis.'

    expect(french.send(:normalize_target_language, residues)).to eq(
      'Les Videha liina sont causés par le bhavapratyaya propre à chacun. ' \
      'Sa&#x301;hitya désigne toutes ces manifestations. ' \
      'la langue Ma&#x301;gadhii de l’époque. ' \
      'Ba Vargiiya et Va Antahstha jusqu’à Osadhipati. ' \
      'La vie humaine et son goal a été formé par l’ajout du suffixe persan. ' \
      'les trois types de vrttis.'
    )
  end

  it 'translates prose while preserving structure, slokas, scripts, markup, and Sanskrit bytes' do
    document, translations = prepare_translation(batch)
    rendered = batch.send(:render, document, translations)

    expect { batch.send(:validate_structure!, source, rendered) }.not_to raise_error
    expect(rendered).to include('Português &ndash; title', 'Traduza-me')
    expect(rendered).not_to include('&amp;ndash;')
    expect(rendered).to include('A&#x301;nanda', '<b>Português markup</b>', '<i>Brahma</i>', 'Prakrti')
    expect(rendered).to include('Ayama&#x301;rambhah shubha&#x301;ya bhavatu.<br>Dharmo raksati raksitah.')
    expect(rendered).to include('<span class=Bengali>&#x09A7;&#x09B0;&#x09CD;&#x09AE;</span>')
    expect(rendered).to include(
      'Português before <span class=Bengali>&#x09A7;&#x09B0;&#x09CD;&#x09AE;</span> Português after.'
    )
    expect(rendered).to include("\r\n")
    expect(rendered).to include('<style>.English { color: red; }</style>')
  end

  it 'preserves an exact malformed character reference inherited from source' do
    unit = batch.send(:prepare_unit, 'malformed-source-entity', 'The marker &nbsp;&nbsp:&nbsp; remains.')

    expect(
      batch.send(:restore_tokens, unit, 'O marcador &nbsp;&nbsp:&nbsp; permanece.')
    ).to eq('O marcador &nbsp;&nbsp:&nbsp; permanece.')
  end

  it 'uses the EWPRS sentence splitter for independent translation units' do
    prepare_translation(batch)

    expect(translator.calls).to include('English plain sentence.')
    expect(translator.calls).to include(a_string_matching(/\A__P\d{4}__English next sentence\.__P\d{4}__\z/))
    expect(translator.calls).not_to include(a_string_including('English plain sentence. <b>'))
  end

  it 'unitizes source-language text left between sentence-splitter boundaries' do
    marker = batch.send(:register_split_gap, ', and ')

    expect(marker).to match(described_class::UNIT_MARKER)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(', and ')
  end

  it 'splits structural content while preserving non-English original verses' do
    document, translations = prepare_translation(batch)
    rendered = batch.send(:render, document, translations)

    expect(translator.calls).to include('English first cell.', 'English second cell.')
    expect(translator.calls).to include('English poetic rendering first line.')
    expect(translator.calls).to include('English poetic rendering second line.')
    expect(batch.instance_variable_get(:@units).values.map(&:source).join).not_to include('Toma')
    expect(rendered).to include(
      'Toma&#x301;r tare ma&#x301;latii ma&#x301;la&#x301;<br>Toma&#x301;r tare sura sa&#x301;dha&#x301;.'
    )
  end

  it 'preserves source-language examples in English grammar tables' do
    grammar = <<~HTML
      <html><body>
      <p class=title><b>Sarkar's English Grammar</b></p>
      <p class=table><TABLE>
      <TR><TD class="BcolHdr">SINGULAR</TD><TD class="BcolHdr">PLURAL</TD></TR>
      <TR><TD>life</TD><TD>lives</TD></TR>
      </TABLE>
      <p><b>In, into, unto:</b> English explanation.</p>
      <table><tr><td>English contents entry</td></tr></table>
      </body></html>
    HTML
    template = batch.send(:unitize, grammar)
    translations = batch.send(:translate_units)
    rendered = batch.send(:render, described_class::Document.new(template: template), translations)

    expect(translator.calls).to include('SINGULAR', 'PLURAL', 'English contents entry')
    expect(translator.calls).not_to include('life', 'lives', 'In, into, unto:')
    expect(rendered).to include(
      '<TD>life</TD><TD>lives</TD>', '<b>In, into, unto:</b> Português explanation.',
      '<td>Português contents entry</td>'
    )
  end

  it 'preserves an inline non-English original before its translated rendering' do
    document, translations = prepare_translation(batch)
    rendered = batch.send(:render, document, translations)

    expect(translator.calls.join).not_to include('Eso A&#x301;y bet&#x301;a&#x301; toke dekhe noba')
    expect(translator.calls).to include(
      a_string_matching(
        %r{English introduction, __P\d{4}__<span data-ewprs="11">&ldquo;English rendering! English second rendering!&rdquo;</span> English after\.}
      )
    )
    expect(rendered).to include(
      'Português introduction, Eso A&#x301;y bet&#x301;a&#x301; toke dekhe noba. ' \
      '[&ldquo;Português rendering! Português second rendering!&rdquo;] Português after.'
    )
  end

  it 'does not protect English prose around marked terms as an inline original' do
    batch.send(
      :unitize,
      '<p>Prakrti [Operative Principle], with Her inherent binding principles, binds ' \
      'Purus&#x301;a, of course with the due permission of Purus&#x301;a, and as a result ' \
      'the Cosmic Mahat [&ldquo;I exist&rdquo;] comes into being.</p>'
    )
    units = batch.instance_variable_get(:@units).values
    outer = units.find { |unit| unit.source.start_with?('Prakrti') }

    expect(outer.tokens.values.join).not_to include('of course with the due permission')
    expect(units.map(&:source)).to include('binds')
  end

  it 'unitizes mixed English prose after foreign-term detection' do
    batch = described_class.new(
      root: root, target: 'ar', cache: cache, translator: translator, stdout: StringIO.new
    )
    source = '<p>And the Tibeto-Chinese languages include Ladhakii, Kinnarii, Kirátii, ' \
             'Lepcá, Yiáru, Gáro, Khaśiya, Mizo and Newari.</p>'

    template = batch.send(:unitize, source)

    expect(template).to match(described_class::UNIT_MARKER)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      a_string_starting_with('And the Tibeto-Chinese languages include')
    )
  end

  it 'unitizes prose around marked linguistic examples' do
    batch = described_class.new(
      root: root, target: 'ar', cache: cache, translator: translator, stdout: StringIO.new
    )
    source = '<p>The word &ldquo;Tamil&rdquo; comes from the word dra&#x301;vid&#x301; &ndash; ' \
             'dra&#x301;vid&#x301; &rarr; dra&#x301;mid&#x301; &rarr; dra&#x301;mil &rarr; ta&#x301;mil.</p>'

    template = batch.send(:unitize, source)

    expect(template).to match(described_class::UNIT_MARKER)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      a_string_starting_with('The word &ldquo;Tamil&rdquo; comes from')
    )
  end

  it 'preserves a coordinated inline original before an unquoted rendering' do
    batch.send(
      :unitize,
      '<p>And Daya&#x301; kare a&#x301;ma&#x301;ke Dilli ja&#x301;ba&#x301;r din ' \
      '[Could you please give me a ticket for Delhi?] becomes shorter.</p>'
    )
    unit = batch.instance_variable_get(:@units).values.find { |value| value.source.include?('Daya') }

    expect(unit.prepared).to match(
      /\AAnd __P\d{4}__<span data-ewprs="11">Could you please give me a ticket for Delhi\?<\/span>/
    )
    expect(unit.tokens.values.join).to include(
      'Daya&#x301; kare a&#x301;ma&#x301;ke Dilli ja&#x301;ba&#x301;r din'
    )
  end

  it 'does not treat lowercase coordination before editorial text as an inline original' do
    batch.send(
      :unitize,
      '<p>So pa&#x301;taka is atonable, but atipa&#x301;taka is not atonable; ' \
      'and maha&#x301;pa&#x301;taka, you know, is the worst type of [ati]pa&#x301;taka.</p>'
    )
    unit = batch.instance_variable_get(:@units).values.find { |value| value.source.start_with?('So ') }

    expect(unit.prepared).to include('is atonable, but', 'you know, is the worst type of')
    expect(unit.tokens.values.join).not_to include('you know')
  end

  it 'distinguishes short title-cased glossary terms from English homographs' do
    prose = batch.send(:prepare_unit, 'english-homograph', 'The jackals sat down.')
    term  = batch.send(:prepare_unit, 'sanskrit-term', 'Sat is the unchangeable entity.')

    expect(prose.prepared).to eq('The jackals sat down.')
    expect(term.tokens.values).to include('Sat')
  end

  it 'keeps translatable glossary words and attached source prose visible' do
    linseed = batch.send(:prepare_unit, 'english-glossary-word', 'After growing linseed, sow dhainca.')
    attached = batch.send(
      :prepare_unit, 'attached-source-prose',
      'Paesha&#x301;cii Pra&#x301;krta-descended and avadhu&#x301;tika&#x301;respectively.'
    )

    expect(linseed.prepared).to include('linseed')
    expect(linseed.tokens.values).not_to include('linseed')
    expect(attached.prepared).to match(/__P0001__ descended and __P0002__ respectively\./)
    expect(attached.tokens.values.join).not_to include('descended', 'respectively')
  end

  it 'does not treat comma-separated glossary entries as an inline original' do
    source = 'ba&#x301;dsha&#x301;h [emperor] (Farsi), nava&#x301;b [nawab] (Farsi), ' \
             'shekh [sheik] (Arabic), a&#x301;lla&#x301;h [God] (Arabic).'

    expect(source).not_to match(described_class::INLINE_ORIGINAL)
  end

  it 'translates a marked Sanskrit gloss as a nested unit' do
    document, translations = prepare_translation(batch)
    rendered = batch.send(:render, document, translations)

    expect(translator.calls).to include('English bliss', 'English middle')
    expect(rendered).to include(
      'Português about <i>A&#x301;nanda karma</i> [Português bliss] e madhyama [Português middle].'
    )
  end

  it 'translates a gloss for an italicized lexicon term as a nested unit' do
    unit = batch.send(:prepare_unit, 'italic-lexicon-gloss', 'This <i>tattva</i> [factor] is original.')

    expect(unit.prepared).to eq('This __P0001__ is original.')
    expect(unit.tokens.fetch('__P0001__')).to match(
      %r{\A<i>tattva</i> \[⟦U[0-9a-f]{64}⟧\]\z}
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('factor')
  end

  it 'translates a gloss for an unknown italicized term as a nested unit' do
    unit = batch.send(:prepare_unit, 'italic-term-gloss', 'Take the <I>jhol</I> [broth] of meat.')

    expect(unit.prepared).to eq('Take the __P0001__ of meat.')
    expect(unit.tokens.fetch('__P0001__')).to match(
      %r{\A<I>jhol</I> \[⟦U[0-9a-f]{64}⟧\]\z}
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('broth')
  end

  it 'nests parenthetical glosses after italicized foreign terms' do
    source = '<I>sam&#x301;ska&#x301;ras</I> (mental momenta), <I>moks&#x301;a</I> ' \
             '(liberation), and <I>kalpas</I> (aeons).'

    outer = batch.send(:prepare_unit, 'italic-parenthetical-glosses', source)

    expect(outer.prepared).to eq('__P0001__, __P0002__, and __P0003__.')
    expect(outer.tokens.values).to all(match(/\A<I>[^<]+<\/I> \(⟦U[0-9a-f]{64}⟧\)\z/))
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'mental momenta', 'liberation', 'aeons'
    )
  end

  it 'translates a gloss after a quoted definition as a nested unit' do
    unit = batch.send(
      :prepare_unit, 'quoted-definition-gloss',
      'The meaning is &ldquo;worshipper of Can&#x301;d&#x301;ika&#x301; Shakti&rdquo; [goddess of power].'
    )

    expect(unit.prepared).to match(
      /\AThe meaning is &ldquo;worshipper of __P0001____P0002__\.\z/
    )
    expect(unit.tokens.values).to include(
      'Can&#x301;d&#x301;ika&#x301; Shakti',
      a_string_matching(/\A&rdquo; \[⟦U[0-9a-f]{64}⟧\]\z/)
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('goddess of power')
  end

  it 'validates quote content around a nested gloss after restoring tokens' do
    unit = batch.send(
      :prepare_unit, 'quoted-nested-gloss',
      'The stove was replaced by an electric &ldquo;heater&rdquo; [hotplate].'
    )
    marker = unit.prepared.scan(/__P\d{4}__/).last

    expect do
      batch.send(:restore_tokens, unit, "Le poêle a été remplacé par un chauffage électrique &ldquo;#{marker}.")
    end.to raise_error(Ewprs::TranslationValidator::Error, /introduced empty smart quotes/)
  end

  it 'translates a gloss for a short consonantal term as a nested unit' do
    unit = batch.send(:prepare_unit, 'consonant-term-gloss', 'In this rk [verse], it has been said.')

    expect(unit.prepared).to eq('In this __P0001__, it has been said.')
    expect(unit.tokens.fetch('__P0001__')).to match(
      %r{\Ark \[⟦U[0-9a-f]{64}⟧\]\z}
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('verse')
  end

  it 'translates the gloss of a term introduced by means as a nested unit' do
    unit = batch.send(:prepare_unit, 'defined-term-gloss', 'shvajana means kukur [dog].')

    expect(unit.prepared).to eq('shvajana means __P0001__.')
    expect(unit.tokens.fetch('__P0001__')).to match(
      %r{\Akukur \[⟦U[0-9a-f]{64}⟧\]\z}
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('dog')
  end

  it 'translates a gloss for a hyphenated technical term as a nested unit' do
    unit = batch.send(
      :prepare_unit, 'hyphenated-term-gloss',
      'The karmaphala-bhoga [reaction] remains in seed [form].'
    )

    expect(unit.prepared).to eq(
      'The __P0001__ remains in seed __P0002__.'
    )
    expect(unit.tokens.fetch('__P0001__')).to match(
      %r{\Akarmaphala-bhoga \[⟦U[0-9a-f]{64}⟧\]\z}
    )
    expect(unit.tokens.fetch('__P0002__')).to match(/\A\[⟦U[0-9a-f]{64}⟧\]\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('reaction', 'form')
  end

  it 'translates coordinated technical glosses after with as nested units' do
    unit = batch.send(
      :prepare_unit, 'coordinated-with-glosses',
      'It is connected neither with hita [welfare] nor with ahita [troubles].'
    )

    expect(unit.prepared).to eq('It is connected neither with __P0001__ nor with __P0002__.')
    expect(unit.tokens.values).to all(match(/\A(?:hita|ahita) \[⟦U[0-9a-f]{64}⟧\]\z/))
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('welfare', 'troubles')
  end

  it 'protects italicized Sanskrit derivations as complete terms' do
    unit = batch.send(
      :prepare_unit, 'italic-sanskrit-derivations',
      '<i>srjanii</i>-<i>pratibha&#x301;;</i> <i>sarjana</i>, <i>utsarjana</i>, <i>visarjana</i>'
    )

    expect(unit.tokens.values).to include(
      '<i>srjanii</i>', '<i>pratibha&#x301;;</i>', '<i>sarjana</i>',
      '<i>utsarjana</i>', '<i>visarjana</i>'
    )
    expect(unit.prepared.scan(described_class::PLACEHOLDER).uniq).to eq(
      unit.prepared.scan(described_class::PLACEHOLDER)
    )
  end

  it 'protects italicized phonemes as complete terms' do
    unit = batch.send(
      :prepare_unit, 'italic-phonemes',
      'the diminished <I>a,</I> the diminished <I>a&#x301;</I>, and the long <I>a</I>'
    )

    expect(unit.prepared).to eq(
      'the diminished __P0001__ the diminished __P0002__, and the long __P0003__'
    )
    expect(unit.tokens.values).to eq(['<I>a,</I>', '<I>a&#x301;</I>', '<I>a</I>'])
  end

  it 'protects a fixed Latin expression as one inline token' do
    unit = batch.send(
      :prepare_unit, 'latin-inline-expression',
      'The <I>sumum bonum</I> of human life lies hidden.'
    )

    expect(unit.prepared).to eq('The __P0001__ of human life lies hidden.')
    expect(unit.tokens).to eq('__P0001__' => '<I>sumum bonum</I>')
  end

  it 'keeps inline punctuation attached to its preceding protected term' do
    unit = batch.send(
      :prepare_unit, 'misplaced-inline-punctuation',
      'Spiritual sadhana<I>,</I> it is called <I>vaekharii</I> <I>siddhi</I>.'
    )

    expect(unit.prepared).to eq(
      'Spiritual __P0001__ it is called __P0002__vaekharii__P0003__ __P0004__siddhi__P0005__.'
    )
    expect(unit.tokens.fetch('__P0001__')).to eq('sadhana<I>,</I>')
  end

  it 'keeps a capitalized name attached to the foreign term it qualifies' do
    unit = batch.send(
      :prepare_unit, 'qualified-name-gloss',
      'He belonged to the Ks&#x301;atriya [warrior] Malla sub-tribe.'
    )

    expect(unit.prepared).to eq('He belonged to the __P0001__ sub-tribe.')
    expect(unit.tokens.fetch('__P0001__')).to match(
      /\AKs&#x301;atriya \[⟦U[0-9a-f]{64}⟧\] Malla\z/
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('warrior')
  end

  it 'keeps an unmarked final word attached to a marked Sanskrit phrase and its gloss' do
    unit = batch.send(
      :prepare_unit, 'marked-phrase-gloss',
      'I read Sada&#x301; satya katha&#x301; balibe [&lsquo;Always speak the truth&rsquo;].'
    )

    expect(unit.prepared).to eq('I read __P0001__.')
    expect(unit.tokens.fetch('__P0001__')).to match(
      /\ASada&#x301; satya katha&#x301; balibe \[⟦U[0-9a-f]{64}⟧\]\z/
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      '&lsquo;Always speak the truth&rsquo;'
    )
  end

  it 'does not protect English sentences before a later bilingual quotation' do
    html = '<p>They accepted, this liun&#x32D;ga pu&#x301;ja&#x301; became common. ' \
           'Subsequently they gave it an interpretation. ' \
           'Liun&#x32D;gate gamyate yasma&#x301;d [&ldquo;All things move toward it&rdquo;].</p>'

    batch.send(:unitize, html)
    sources = batch.instance_variable_get(:@units).values.map(&:source)

    expect(sources.join(' ')).to include('Subsequently they gave it an interpretation.')
    expect(sources.join).not_to match(described_class::PROTECTED_MARKER)
  end

  it 'does not absorb English prose between marked Sanskrit terms into a gloss token' do
    unit = batch.send(
      :prepare_unit, 'marked-term-prose',
      'The goal of sa&#x301;dhana&#x301; is to awaken the dormant jiivashakti [unit force].'
    )

    expect(unit.prepared).to match(
      /The goal of __P\d{4}__ is to awaken the dormant __P\d{4}__\./
    )
    expect(unit.tokens.values).not_to include(a_string_including('is to awaken the dormant'))
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('unit force')
  end

  it 'translates a gloss for an unmarked ASCII-transliterated term as a nested unit' do
    unit = batch.send(:prepare_unit, 'ascii-gloss', 'The pratiika [emblem] is used.')

    expect(unit.prepared).to eq('The __P0001__ is used.')
    expect(unit.tokens.fetch('__P0001__')).to match(
      /\Apratiika \[⟦U[0-9a-f]{64}⟧\]\z/
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('emblem')
  end

  it 'keeps a known Sanskrit term attached to its nested gloss' do
    unit = batch.send(
      :prepare_unit, 'known-bracketed-gloss',
      'To merge in Brahmatva [Cosmic Consciousness], after first elevating themselves to ' \
      'devatva [god-hood], was their sa&#x301;dhana&#x301;.'
    )

    expect(unit.prepared).to eq(
      'To merge in __P0001__, after first elevating themselves to __P0002__, was their __P0003__.'
    )
    expect(unit.tokens.fetch('__P0002__')).to match(/\Adevatva \[⟦U[0-9a-f]{64}⟧\]\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('god-hood')
  end

  it 'translates a parenthetical gloss for an ASCII-transliterated phrase' do
    unit = batch.send(:prepare_unit, 'ascii-phrase-gloss', 'A videhii mana (bodiless mind) cannot function.')

    expect(unit.prepared).to eq('A __P0001__ cannot function.')
    expect(unit.tokens.fetch('__P0001__')).to match(
      /\Avidehii mana \(⟦U[0-9a-f]{64}⟧\)\z/
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('bodiless mind')
  end

  it 'does not absorb English prose after an ASCII-transliterated word' do
    unit = batch.send(
      :prepare_unit, 'ascii-word-before-prose',
      'Videha liina are caused by ones bhavapratyaya (bundle of samska&#x301;ras).'
    )

    expect(unit.prepared).to eq('Videha liina are caused by ones bhavapratyaya __P0001__.')
    expect(unit.tokens.fetch('__P0001__')).to match(/\A\(⟦U[0-9a-f]{64}⟧\)\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('bundle of samska&#x301;ras')
  end

  it 'keeps a marked parenthetical foreign equivalent immutable' do
    unit = batch.send(
      :prepare_unit, 'parenthetical-foreign-equivalent',
      'The maternal uncle (canda&#x301;ma&#x301;ma) of all.'
    )

    expect(unit.prepared).to eq('__P0001__ of all.')
    expect(unit.tokens.fetch('__P0001__')).to match(
      /\A⟦U[0-9a-f]{64}⟧ \(canda&#x301;ma&#x301;ma\)\z/
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('The maternal uncle')
  end

  it 'nests a parenthetical gloss for a known Sanskrit term' do
    unit = batch.send(
      :prepare_unit, 'known-parenthetical-gloss',
      'One meaning is kula (family or lineage), whose greatness is recognized.'
    )
    title_case = batch.send(
      :prepare_unit, 'title-case-parenthetical-gloss',
      'They understand Japa (repetition of mantra).'
    )
    sentence = batch.send(
      :prepare_unit, 'known-term-in-sentence',
      'The dharma of agni (fire) is to burn.'
    )

    expect(unit.prepared).to eq('One meaning is __P0001__, whose greatness is recognized.')
    expect(unit.tokens.fetch('__P0001__')).to match(/\Akula \(⟦U[0-9a-f]{64}⟧\)\z/)
    expect(title_case.prepared).to eq('They understand __P0001__.')
    expect(sentence.prepared).to eq('The __P0001__ of __P0002__ is to burn.')
    expect(sentence.tokens.fetch('__P0002__')).to match(/\Aagni \(⟦U[0-9a-f]{64}⟧\)\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'family or lineage', 'repetition of mantra', 'fire'
    )
  end

  it 'nests a gloss for a known multi-word domain term' do
    unit = batch.send(
      :prepare_unit, 'known-multi-word-gloss',
      'Maharshi Patanjali propounded Yoga  Darshana [Yoga Philosophy].'
    )

    expect(unit.prepared).to eq('Maharshi Patanjali propounded __P0001__.')
    expect(unit.tokens.fetch('__P0001__')).to match(
      /\AYoga  Darshana \[⟦U[0-9a-f]{64}⟧\]\z/
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('Yoga Philosophy')
  end

  it 'does not split a marked word after a Sanskrit gloss' do
    unit = batch.send(
      :prepare_unit, 'marked-word-after-gloss',
      'The practice of pravrttimu&#x301;laka [extroversial] Pain&#x32D;camaka&#x301;ra continues.'
    )

    expect(unit.prepared).to eq('The practice of __P0001__ __P0002__ continues.')
    expect(unit.tokens.fetch('__P0002__')).to eq('Pain&#x32D;camaka&#x301;ra')
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('extroversial')
  end

  it 'translates a gloss for an unmarked proper name as a nested unit' do
    unit = batch.send(:prepare_unit, 'proper-name-gloss', 'He came from Damunya [village].')

    expect(unit.prepared).to eq('He came from __P0001__.')
    expect(unit.tokens.fetch('__P0001__')).to match(
      /\ADamunya \[⟦U[0-9a-f]{64}⟧\]\z/
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('village')
  end

  it 'does not treat a capitalized English function word as a proper-name gloss' do
    unit = batch.send(:prepare_unit, 'function-word-editorial', 'This [editorial] sentence continues.')

    expect(unit.prepared).to eq('This <span data-ewprs="11">editorial</span> sentence continues.')
  end

  it 'keeps delimiters balanced when editorial content interrupts a sentence' do
    source = 'English before (foreign term [English gloss], etc.) English after.'

    batch.send(:register_content, source)

    outer = batch.instance_variable_get(:@units).values.find { |unit| unit.source.start_with?('English before') }
    expect(outer.source).to eq(source)
    expect(outer.prepared).to match(
      %r{\AEnglish before __P\d{4}__foreign term <span data-ewprs="11">English gloss</span>, etc\.__P\d{4}__ English after\.\z}
    )
  end

  it 'registers editorial units before creating outer protected placeholders' do
    source = 'English before [<i>A&#x301;nanda karma</i> English gloss] English after.'

    expect { batch.send(:register_content, source) }.not_to raise_error
    expect(batch.instance_variable_get(:@units).values).to all(
      satisfy { |unit| (unit.prepared.scan(described_class::PLACEHOLDER).uniq - unit.tokens.keys).empty? }
    )
  end

  it 'nests editorial possessive phrases that require target-language restructuring' do
    unit = batch.send(
      :prepare_unit, 'editorial-possessive-phrase',
      'The Ketu [dragon&#146;s tail] is also called kabandha.'
    )

    expect(unit.prepared).to eq('The Ketu __P0001__ is also called kabandha.')
    expect(unit.tokens.fetch('__P0001__')).to match(/\A\[⟦U[0-9a-f]{64}⟧\]\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'dragon&#146;s tail'
    )
  end

  it 'sentence-splits content enclosed by one outer editorial bracket pair' do
    template = batch.send(:register_content, '[First English sentence. Second English sentence.]')

    expect(template).to match(/\A\[⟦U[0-9a-f]{64}⟧ ⟦U[0-9a-f]{64}⟧\]\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'First English sentence.', 'Second English sentence.'
    )
    expect(batch.instance_variable_get(:@units).values.map(&:prepared).join).not_to include('data-ewprs')
  end

  it 'keeps multi-sentence parentheticals in the surrounding sentence' do
    source = 'English before (First sentence. Second sentence.) English after.'
    template = batch.send(:register_content, source)

    outer = batch.instance_variable_get(:@units).values.find { |unit| unit.source == source }
    expect(template).to eq("⟦U#{outer.key}⟧")
    expect(outer.prepared).to match(/\AEnglish before __P\d{4}__ English after\.\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'First sentence. Second sentence.'
    )
  end

  it 'keeps alphabetic list labels outside translation units' do
    alphabetic = batch.send(:register_content, 'c) English list item.')
    numeric = batch.send(:register_content, '5) Another English list item.')
    units = batch.instance_variable_get(:@units).values

    expect(alphabetic).to eq("c) ⟦U#{units[0].key}⟧")
    expect(numeric).to eq("5) ⟦U#{units[1].key}⟧")
    expect(units.map(&:source)).to eq(['English list item.', 'Another English list item.'])
    expect(units.flat_map { |unit| unit.tokens.values }).not_to include(')')
  end

  it 'does not register a nested foreign editorial passage for translation' do
    batch.send(:register_content, 'English before [Sa no buddhya shubhayá saḿyunaktu] English after.')
    batch.send(:register_content, 'English before (Sa no buddhya shubhayá saḿyunaktu) English after.')

    expect(batch.instance_variable_get(:@units).values.map(&:source)).not_to include(
      'Sa no buddhya shubhayá saḿyunaktu'
    )
  end

  it 'nests parentheticals containing several foreign terms' do
    source = 'The hand indriya (in Sam&#x301;skrta the palm is pa&#x301;n&#x301;i) becomes active.'

    outer = batch.send(:prepare_unit, 'dense-parenthetical', source)

    expect(outer.prepared.scan(described_class::PLACEHOLDER).size).to eq(1)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'in Sam&#x301;skrta the palm is pa&#x301;n&#x301;i'
    )
  end

  it 'nests long parenthetical clauses' do
    parenthetical = 'situated in the Rarh area of Bengal, west of the Bhagirathi River'
    outer = batch.send(:prepare_unit, 'long-parenthetical', "The village (#{parenthetical}) is old.")

    expect(outer.prepared).to eq('The village __P0001__ is old.')
    expect(outer.tokens.fetch('__P0001__')).to match(/\A\(⟦U[0-9a-f]{64}⟧\)\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(parenthetical)
  end

  it 'nests short multi-word parenthetical clauses' do
    outer = batch.send(
      :prepare_unit, 'short-parenthetical',
      'The poet came from Siddhi village (modern Singi village) of Burdwan.'
    )
    single_word = batch.send(
      :prepare_unit, 'single-word-parenthetical', 'Indefinite (general) article:'
    )

    expect(outer.prepared).to eq('The poet came from Siddhi village __P0001__ of Burdwan.')
    expect(outer.tokens.fetch('__P0001__')).to match(/\A\(⟦U[0-9a-f]{64}⟧\)\z/)
    expect(single_word.prepared).to eq('Indefinite __P0001__ article:')
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'modern Singi village', 'general'
    )
  end

  it 'nests formula-style parentheticals' do
    formula = 'vyoma = &ldquo;sky&rdquo; and kesh = &ldquo;hair&rdquo;'
    outer = batch.send(:prepare_unit, 'formula-parenthetical', "The terms (#{formula}) are used.")

    expect(outer.prepared).to eq('The terms __P0001__ are used.')
    expect(outer.tokens.fetch('__P0001__')).to match(/\A\(⟦U[0-9a-f]{64}⟧\)\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(formula)
  end

  it 'nests coordinated parenthetical glosses and preserves both foreign terms' do
    source = 'The mind is bound by ripus (enemies) and pa&#x301;shas (fetters).'

    outer = batch.send(:prepare_unit, 'coordinated-glosses', source)

    expect(outer.prepared).to eq('The mind is bound by __P0001__ and __P0002__.')
    expect(outer.tokens.values).to contain_exactly(
      a_string_matching(/\Aripus \(⟦U[0-9a-f]{64}⟧\)\z/),
      a_string_matching(/\Apa&#x301;shas \(⟦U[0-9a-f]{64}⟧\)\z/)
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('enemies', 'fetters')
  end

  it 'nests operator-linked parenthetical definitions' do
    unit = batch.send(
      :prepare_unit, 'formula-parenthetical-glosses',
      'The word upava&#x301;sa is derived upa (prefix) &ndash; vas (root verb) + ghain&#x32D; (suffix).'
    )

    expect(unit.prepared).to match(
      /\AThe word __P0001__ is derived __P0002__ &ndash; __P0003__ \+ __P0004__\.\z/
    )
    expect(unit.tokens.values).to include(
      a_string_matching(/\Aupa \(⟦U[0-9a-f]{64}⟧\)\z/),
      a_string_matching(/\Avas \(⟦U[0-9a-f]{64}⟧\)\z/),
      a_string_matching(/\Aghain&#x32D; \(⟦U[0-9a-f]{64}⟧\)\z/)
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'prefix', 'root verb', 'suffix'
    )
  end

  it 'nests every gloss in a longer coordinated parenthetical list' do
    source = 'Vista&#x301;ra (expansion), rasa (flow), seva (service) and ' \
             'tadsthiti (attainment of the Supreme) are aspects of human existence.'

    outer = batch.send(:prepare_unit, 'coordinated-gloss-list', source)

    expect(outer.prepared).to eq(
      '__P0001__, __P0002__, __P0003__ and __P0004__ are aspects of human existence.'
    )
    expect(outer.tokens.values).to all(match(/\A[^()]+ \(⟦U[0-9a-f]{64}⟧\)\z/))
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'expansion', 'flow', 'service', 'attainment of the Supreme'
    )
  end

  it 'nests one shared gloss without hiding the coordinated Sanskrit terms' do
    source = 'The goals are dharma, artha, ka&#x301;ma and moks&#x301;a ' \
             '(psychic, physical and spiritual attainment, respectively).'

    outer = batch.send(:prepare_unit, 'coordinated-terms-shared-gloss', source)

    expect(outer.prepared).to eq(
      'The goals are __P0001__, __P0002__, __P0003__ and __P0004__ __P0005__.'
    )
    expect(outer.tokens.values).to include('dharma', 'artha', 'ka&#x301;ma', 'moks&#x301;a')
    expect(outer.tokens.fetch('__P0005__')).to match(
      /\A\(⟦U[0-9a-f]{64}⟧\)\z/
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'psychic, physical and spiritual attainment, respectively'
    )
  end

  it 'keeps a parenthetical qualifier with the term it precedes' do
    source = 'Kashmir Sa&#x301;rasvata, Dogri Sa&#x301;rasvata and ' \
             'Saptanada (Punjabi) Sa&#x301;rasvata.'

    outer = batch.send(:prepare_unit, 'parenthetical-term-qualifier', source)

    expect(outer.tokens.values).not_to include(a_string_including('and Saptanada'))
    expect(outer.prepared).to match(/and Saptanada __P\d{4}__ __P\d{4}__\./)
    expect(outer.tokens.values).to include(a_string_matching(/\A\(⟦U[0-9a-f]{64}⟧\)\z/))
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('Punjabi')
  end

  it 'nests coordinated bracketed glosses when the second foreign term is unmarked' do
    source = 'Change occurs through kra&#x301;nti [evolution] or viplava [revolution].'

    outer = batch.send(:prepare_unit, 'coordinated-bracketed-glosses', source)

    expect(outer.prepared).to eq('Change occurs through __P0001__ or __P0002__.')
    expect(outer.tokens.values).to contain_exactly(
      a_string_matching(/\Akra&#x301;nti \[⟦U[0-9a-f]{64}⟧\]\z/),
      a_string_matching(/\Aviplava \[⟦U[0-9a-f]{64}⟧\]\z/)
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('evolution', 'revolution')
  end

  it 'makes one protected occurrence explicit across quantified coordination' do
    unit = batch.send(
      :prepare_unit, 'coordination',
      'Vital energy passes through five internal and five external Vayus (airs).'
    )

    expect(unit.prepared).to eq(
      'Vital energy passes through five internal __P0001__ and five external ones __P0002__airs__P0003__.'
    )
    expect(unit.tokens).to eq(
      '__P0001__' => 'Vayus', '__P0002__' => '(', '__P0003__' => ')'
    )
  end

  it 'coalesces adjacent protected words into one exact source term' do
    unit = batch.send(
      :prepare_unit, 'compound',
      'Was Ka&#x301;shyapa Sa&#x301;gar named after him?'
    )

    expect(unit.prepared).to eq('Was __P0001__ named after him?')
    expect(unit.tokens).to eq('__P0001__' => 'Ka&#x301;shyapa Sa&#x301;gar')
  end

  it 'coalesces a marked qualifier with a known domain name' do
    unit = batch.send(
      :prepare_unit, 'marked-domain-name',
      'The Daks&#x301;in&#x301;ii Khotta Bengali dialect is spoken here.'
    )

    expect(unit.prepared).to eq('The __P0001__ Bengali dialect is spoken here.')
    expect(unit.tokens).to eq('__P0001__' => 'Daks&#x301;in&#x301;ii Khotta')
  end

  it 'coalesces marked terms with known language names in etymologies' do
    unit = batch.send(
      :prepare_unit, 'etymology-language-names',
      'After crossing the Saptasindhu, this became Hariaha&#x301;nya in Shaorasenii ' \
      'Pra&#x301;krta and Hariha&#x301;na&#x301; in Demi-Shaorasenii.'
    )

    expect(unit.tokens.values).to include(
      'Saptasindhu', 'Hariaha&#x301;nya', 'Shaorasenii Pra&#x301;krta',
      'Hariha&#x301;na&#x301;', 'Demi-Shaorasenii'
    )
  end

  it 'protects source forms and language names in etymological prose' do
    unit = batch.send(
      :prepare_unit, 'etymological-source-forms',
      'In the Vaedika era &ldquo;arya&rdquo; became &ldquo;ajja&rdquo;, then &ldquo;ajjii&rdquo; in Ardha Shaorasenii.'
    )

    expect(unit.tokens.values).to include('Vaedika', 'arya', 'ajja', 'ajjii', 'Ardha Shaorasenii')
  end

  it 'protects a named marked plural group as one semantic term' do
    unit = batch.send(
      :prepare_unit, 'named-marked-group',
      'The branches of Chitragupta Ka&#x301;yasthas are known.'
    )

    expect(unit.prepared).to eq('The branches of __P0001__ are known.')
    expect(unit.tokens).to eq('__P0001__' => 'Chitragupta Ka&#x301;yasthas')
  end

  it 'protects an official title in a dated bibliographic reference' do
    unit = batch.send(
      :prepare_unit, 'bibliographic-title',
      'For further discussion, see A Guide to Human Conduct, 1957.'
    )

    expect(unit.prepared).to eq('For further discussion, see __P0001__, 1957.')
    expect(unit.tokens).to eq('__P0001__' => 'A Guide to Human Conduct')
  end

  it 'protects a dated bibliographic title after its author' do
    unit = batch.send(
      :prepare_unit, 'authored-bibliographic-title',
      'See Shrii Shrii A&#x301;nandamu&#x301;rti, A Guide to Human Conduct, 1960.'
    )

    expect(unit.tokens.values).to include('A Guide to Human Conduct')
  end

  it 'protects complete titles in a dated reference list' do
    article = '&ldquo;The Acoustic Roots of the Indo-Aryan Alphabet&rdquo;'
    book = 'Ananda Marga Philosophy in a Nutshell Part 8'
    unit = batch.send(
      :prepare_unit, 'dated-reference-list',
      "For more information, see #{article} in #{book}, 1988, or " \
      '&ldquo;Plexi and Microvita&rdquo; in Yoga Psychology, 1998, or ' \
      'Discourses on Tantra Volume 1, 1993.'
    )

    expect(unit.tokens.values).to include(
      article, book, '&ldquo;Plexi and Microvita&rdquo;', 'Yoga Psychology',
      'Discourses on Tantra Volume 1'
    )

    ordinary = batch.send(
      :prepare_unit, 'ordinary-publication-prose',
      'It was published in English in Supreme Expression I, 1990.'
    )
    expect(ordinary.tokens.values).not_to include('English in Supreme Expression I')

    volume = batch.send(
      :prepare_unit, 'dated-volume-publication-prose',
      'The publication was in English in the August 1970 Cosmic Society Vol. 8, No. 6.'
    )
    expect(volume.tokens.values).to include('Cosmic Society')
    expect(volume.tokens.values).not_to include('English in the August 1970 Cosmic Society')
  end

  it 'protects an official quoted publication title' do
    unit = batch.send(
      :prepare_unit, 'quoted-publication-title',
      'Originally published in English as &ldquo;Devotion: The Only Way of Salvation&rdquo; in 1966.'
    )

    expect(unit.prepared).to eq('Originally published in English as __P0001__ in 1966.')
    expect(unit.tokens).to eq(
      '__P0001__' => '&ldquo;Devotion: The Only Way of Salvation&rdquo;'
    )

    noun_form = batch.send(
      :prepare_unit, 'quoted-publication-title-noun',
      'First English publication as &ldquo;Longings of Microcosms&rdquo; in a magazine.'
    )
    expect(noun_form.tokens).to eq('__P0001__' => '&ldquo;Longings of Microcosms&rdquo;')

    plural = batch.send(
      :prepare_unit, 'quoted-publication-title-plural',
      'First published in English as parts of &ldquo;All Bask in the Glory of Shiva &ndash; 1&rdquo;.'
    )
    expect(plural.tokens).to eq(
      '__P0001__' => '&ldquo;All Bask in the Glory of Shiva &ndash; 1&rdquo;'
    )
  end

  it 'protects title-case quoted works but not ordinary quotations' do
    title = batch.send(
      :prepare_unit, 'title-case-quote',
      '&ldquo;Plus and Minus Make It Zero&rdquo; came from Timmern, and ' +
        '&ldquo;He Thinks and We Perceive&rdquo; from Reykjavik.'
    )
    ordinary = batch.send(
      :prepare_unit, 'ordinary-quote',
      'They said &ldquo;parents or guardians should attend&rdquo;.'
    )

    expect(title.tokens).to eq(
      '__P0001__' => '&ldquo;Plus and Minus Make It Zero&rdquo;',
      '__P0002__' => '&ldquo;He Thinks and We Perceive&rdquo;'
    )
    expect(ordinary.tokens.values).not_to include('&ldquo;parents or guardians should attend&rdquo;')
  end

  it 'protects an ASCII-quoted cited title and its marked numbered publication' do
    unit = batch.send(
      :prepare_unit, 'ascii-quoted-numbered-citation',
      'See "Ta&#x301;n&#x301;d&#x301;ava Dance &ndash; What and Why?" in ' \
      'A&#x301;nanda Vacana&#x301;mrtam Part 10. &ndash;Trans.'
    )

    expect(unit.prepared).to eq('See __P0001__ in __P0002__. &ndash;Trans.')
    expect(unit.tokens).to eq(
      '__P0001__' => '"Ta&#x301;n&#x301;d&#x301;ava Dance &ndash; What and Why?"',
      '__P0002__' => 'A&#x301;nanda Vacana&#x301;mrtam Part 10'
    )
  end

  it 'does not span prose between quoted titles in a numbered citation' do
    second = '&ldquo;Dialogues of Shiva and Pa&#x301;rvatii&rdquo;'
    unit = batch.send(
      :prepare_unit, 'separated-numbered-citation',
      'The discourse &ldquo;The Dialogues of Shiva and Pa&#x301;rvatii &ndash; 5&rdquo; would have been ' \
      "published together with the other 1967 #{second} in A&#x301;nanda Vacana&#x301;mrtam Part 23."
    )

    expect(unit.prepared).to include('would have been published together with the other 1967')
    expect(unit.tokens.values).to include(second, 'A&#x301;nanda Vacana&#x301;mrtam Part 23')
    expect(unit.tokens.values.join).not_to include('would have been published')
  end

  it 'protects comma-separated quoted and container titles in a dated footnote citation' do
    unit = batch.send(
      :prepare_unit, 'comma-separated-dated-citation',
      '<a name="24.fn1"></a>(<b><a href="#Ref.24.fn1">1</a></b>)  ' \
      '&ldquo;Timesweep&rdquo;, in Honey and Salt, 1963. &ndash;Eds.'
    )

    expect(unit.prepared).to eq(
      '__P0001____P0002____P0003__  __P0004__, in __P0005__, 1963. &ndash;Eds.'
    )
    expect(unit.tokens.values_at('__P0004__', '__P0005__')).to eq(
      ['&ldquo;Timesweep&rdquo;', 'Honey and Salt']
    )
  end

  it 'protects quoted and container titles in relative publication context' do
    unit = batch.send(
      :prepare_unit, 'relative-publication-context',
      'None has previously been published except &ldquo;Blind Mind and Conscience&rdquo;, which appeared in ' \
      'Discourses on Krs&#x301;n&#x301;a and the Giita&#x301; earlier this year.'
    )

    expect(unit.prepared).to eq(
      'None has previously been published except __P0001__, which appeared in __P0002__ earlier this year.'
    )
    expect(unit.tokens).to eq(
      '__P0001__' => '&ldquo;Blind Mind and Conscience&rdquo;',
      '__P0002__' => 'Discourses on Krs&#x301;n&#x301;a and the Giita&#x301;'
    )
  end

  it 'protects every title in a list of previous publication aliases' do
    unit = batch.send(
      :prepare_unit, 'publication-alias-list',
      'To summarize: the discourse &ldquo;Are Sam&#x301;giita and Supra-Aesthetic Science Inseparable?&rdquo; ' \
      'has appeared previously as &ldquo;Supra-Aesthetic Science and Music&rdquo;, ' \
      '&ldquo;What I Said in Switzerland&rdquo; as &ldquo;Dance, Mudra&#x301; and Tantra&rdquo;.'
    )

    expect(unit.prepared).to eq(
      'To summarize: the discourse __P0001__ has appeared previously as __P0002__, __P0003__ as __P0004__.'
    )
    expect(unit.tokens.values).to eq(
      [
        '&ldquo;Are Sam&#x301;giita and Supra-Aesthetic Science Inseparable?&rdquo;',
        '&ldquo;Supra-Aesthetic Science and Music&rdquo;',
        '&ldquo;What I Said in Switzerland&rdquo;',
        '&ldquo;Dance, Mudra&#x301; and Tantra&rdquo;'
      ]
    )
  end

  it 'protects publication titles containing existing translations' do
    unit = batch.send(
      :prepare_unit, 'translation-publications',
      'Two translations were found, the earlier of the two in both Cosmic Society and Education and Culture ' \
      'and the later of the two in Bodhi Kalpa.'
    )

    expect(unit.prepared).to eq(
      'Two translations were found, the earlier of the two in both __P0001__ and __P0002__ ' \
      'and the later of the two in __P0003__.'
    )
    expect(unit.tokens.values).to eq(['Cosmic Society', 'Education and Culture', 'Bodhi Kalpa'])
  end

  it 'protects book titles cited as chapter sources' do
    unit = batch.send(
      :prepare_unit, 'chapter-source-publications',
      'Chapter one is taken from the first chapter of Ananda Marga: Elementary Philosophy; ' \
      'chapters six and seventeen from Idea and Ideology; chapters eleven and fourteen from ' \
      'Abhimata: The Opinion; chapters four and eight from The Human Society Part I; chapter eighteen ' \
      'from The Human Society Part II; and chapter twenty is from A&#x301;nanda Su&#x301;tram.'
    )

    expect(unit.tokens.values).to include(
      'Ananda Marga: Elementary Philosophy', 'Idea and Ideology', 'Abhimata: The Opinion',
      'The Human Society Part I', 'The Human Society Part II'
    )
    expect(unit.prepared).to include(
      'chapter of __P0001__;', 'from __P0002__;', 'from __P0003__;',
      'from __P0004__;', 'from __P0005__;'
    )

    ordinary = batch.send(
      :prepare_unit, 'ordinary-semicolon-locations',
      'Limestone from Purulia district can be used for cement; the tabla came from Persia but this is false; ' \
      'You are separate from You because You are composite; then continue.'
    )
    expect(ordinary.tokens.values.join).not_to include(
      'Purulia district can be used for cement', 'Persia but this is false', 'You because You are composite'
    )
  end

  it 'protects a standalone numbered publication title' do
    unit = batch.send(:prepare_unit, 'standalone-numbered-title', 'Prout in a Nutshell 21')

    expect(unit.prepared).to eq('__P0001__')
    expect(unit.tokens).to eq('__P0001__' => 'Prout in a Nutshell 21')
  end

  it 'protects a quoted work introduced as a title' do
    unit = batch.send(
      :prepare_unit, 'introduced-title',
      'The manuscript is titled &ldquo;The Cimmerian Darkness at Long Last Penetrated&rdquo;.'
    )

    expect(unit.tokens).to eq(
      '__P0001__' => '&ldquo;The Cimmerian Darkness at Long Last Penetrated&rdquo;'
    )
  end

  it 'protects quoted source-language examples in linguistic contexts' do
    unit = batch.send(
      :prepare_unit, 'quoted-language-examples',
      'In English we use &ldquo;to&rdquo; in the phrase &ldquo;He is going to Calcutta&rdquo;; ' \
      'one says: &ldquo;The patient had died before the doctor arrived.&rdquo;'
    )

    expect(unit.prepared).to eq(
      'In English we use __P0001__ in the phrase __P0002__; one says: __P0003__'
    )
    expect(unit.tokens.values).to eq(
      [
        '&ldquo;to&rdquo;', '&ldquo;He is going to Calcutta&rdquo;',
        '&ldquo;The patient had died before the doctor arrived.&rdquo;'
      ]
    )
  end

  it 'does not protect ordinary quoted prose merely introduced by said' do
    quote = '&ldquo;Maharshi Patanjali, the propounder [of Yoga Philosophy], was born here.&rdquo;'
    unit = batch.send(
      :prepare_unit, 'ordinary-said-prose',
      "Elsewhere the author has said: #{quote}"
    )

    expect(unit.tokens.values).not_to include(quote)
    expect(unit.prepared).to match(
      /<span data-ewprs="11">of __P\d{4}__ Philosophy<\/span>/
    )
    expect(unit.tokens.values.join).not_to include('⟦E11⟧')
  end

  it 'protects an unquoted title in an inclusion citation' do
    unit = batch.send(
      :prepare_unit, 'included-title',
      'Seventeen songs were included in Songs of the New Dawn in which there is a feminine outlook.'
    )

    expect(unit.tokens).to eq('__P0001__' => 'Songs of the New Dawn')
  end

  it 'protects publication titles in part and volume citations' do
    parted = batch.send(
      :prepare_unit, 'parted-publication-title',
      'Third English publication in Ananda Marga Ideology and Way of Life in a Nutshell, Part 2, 1988.'
    )
    volume = batch.send(
      :prepare_unit, 'numbered-series-title',
      'Published as part of &ldquo;How to Unite Human Society&rdquo; in Prout in a Nutshell 21, 1991.'
    )
    undated = batch.send(
      :prepare_unit, 'undated-numbered-series-title',
      'This discourse was formerly in Prout in a Nutshell Part 10.'
    )

    expect(parted.tokens.values).to include('Ananda Marga Ideology and Way of Life in a Nutshell')
    expect(volume.tokens.values).to include(
      '&ldquo;How to Unite Human Society&rdquo;', 'Prout in a Nutshell 21'
    )
    expect(undated.tokens.values).to include('Prout in a Nutshell Part 10')
  end

  it 'protects a dated publication title and subtitle' do
    unit = batch.send(
      :prepare_unit, 'dated-publication-title',
      'First English publication in Prabha&#x301;ta Sam&#x301;giita: The Lyrics and their English Renderings, 1993.'
    )

    expect(unit.tokens.values).to include(
      'Prabha&#x301;ta Sam&#x301;giita: The Lyrics and their English Renderings'
    )
  end

  it 'protects italicized citation titles before editions and years' do
    unit = batch.send(
      :prepare_unit, 'italic-citation-titles',
      'in <i>Prout in a Nutshell Volume 1 Part 4,</i> 1st edition or <i>A Guide to Human Conduct,</i> 1957'
    )

    expect(unit.tokens.values).to include(
      '<i>Prout in a Nutshell Volume 1 Part 4,</i>', '<i>A Guide to Human Conduct,</i>'
    )

    textual = batch.send(
      :prepare_unit, 'textual-edition-title',
      'This book is <i>Prout in a Nutshell Volume One,</i> Second Edition.'
    )
    preceding = batch.send(
      :prepare_unit, 'preceded-edition-title',
      'This Second Edition of <i>Prout in a Nutshell Volume One</i> is current.'
    )
    expect(textual.tokens.values).to include('<i>Prout in a Nutshell Volume One,</i>')
    expect(preceding.tokens.values).to include('<i>Prout in a Nutshell Volume One</i>')
  end

  it 'protects discourse and book titles in publication history' do
    discourse = '&ldquo;&#x301;Take Refuge in Parama Purus&#x301;a with Unswerving Attention&#146;&rdquo;'
    book = '<I>A Few Problems Solved Part 3,</I>'
    unit = batch.send(
      :prepare_unit, 'publication-history-titles',
      "The discourse #{discourse} had appeared in #{book}."
    )

    expect(unit.tokens.values).to include(discourse, book)
  end

  it 'protects an unquoted title introduced as a book' do
    unit = batch.send(
      :prepare_unit, 'introduced-book-title',
      'Please refer to the book A Guide to Human Conduct.'
    )

    expect(unit.tokens).to eq('__P0001__' => 'A Guide to Human Conduct')
  end

  it 'protects unquoted titles before citation years and editions' do
    year = batch.send(
      :prepare_unit, 'parenthetical-citation-title',
      'See especially A Guide to Human Conduct (1961).'
    )
    edition = batch.send(
      :prepare_unit, 'editioned-citation-title',
      'This version appears in A Guide to Human Conduct, 4th edition.'
    )
    printed = batch.send(
      :prepare_unit, 'printed-edition-title',
      'This version is the printed A Guide to Human Conduct, 4th edition, 5th printing.'
    )
    numbered = batch.send(
      :prepare_unit, 'printed-numbered-edition-title',
      'This version is the printed Ananda Marga Ideology and Way of Life in a Nutshell Part 1, ' \
      '1st edition, version.'
    )

    expect(year.tokens.values).to include('A Guide to Human Conduct')
    expect(edition.tokens.values).to include('A Guide to Human Conduct')
    expect(printed.tokens.values).to include('A Guide to Human Conduct')
    expect(numbered.tokens.values).to include(
      'Ananda Marga Ideology and Way of Life in a Nutshell Part 1'
    )
  end

  it 'protects an unquoted title before a numbered volume citation' do
    unit = batch.send(
      :prepare_unit, 'volume-citation-title',
      'The story appears in The Life and Teachings of Shrii Shrii A&#x301;nandamu&#x301;rti Vol. 1, p. 37.'
    )

    expect(unit.tokens.values).to include(
      'The Life and Teachings of Shrii Shrii A&#x301;nandamu&#x301;rti'
    )
  end

  it 'protects a semicolon-delimited publication list' do
    works = 'Ananda Marga Philosophy in a Nutshell Parts 1-8; A Guide to Human Conduct; ' \
            'and Ananda Marga: Elementary Philosophy'
    unit = batch.send(
      :prepare_unit, 'publication-list',
      "Discourses have been published in works such as #{works}."
    )

    expect(unit.prepared).to eq('Discourses have been published in works such as __P0001__.')
    expect(unit.tokens).to eq('__P0001__' => works)
  end

  it 'protects magazine titles while leaving the list suffix translatable' do
    titles = 'Cosmic Society, Bodhi Kalpa, Education and Culture'
    unit = batch.send(
      :prepare_unit, 'magazine-list',
      "Previously printed in the magazines: #{titles} and others."
    )

    expect(unit.prepared).to eq('Previously printed in the magazines: __P0001__ and others.')
    expect(unit.tokens).to eq('__P0001__' => titles)
  end

  it 'coalesces Sanskrit derivation clauses into exact source terms' do
    unit = batch.send(
      :prepare_unit, 'derivation',
      'Pra karoti iti Prakrti &ndash; praka&#x301;ram&#x301; karoti iti Prakrti.'
    )

    expect(unit.prepared).to eq('__P0001__ &ndash; __P0002__.')
    expect(unit.tokens).to eq(
      '__P0001__' => 'Pra karoti iti Prakrti',
      '__P0002__' => 'praka&#x301;ram&#x301; karoti iti Prakrti'
    )
  end

  it 'canonicalizes protected placeholders in textual order after coalescing' do
    unit = batch.send(
      :prepare_unit, 'canonical-placeholders',
      'Nihitam&#x301; guha&#x301;ya&#x301;m &ndash; He lies within guha&#x301;.'
    )

    expect(unit.prepared.scan(described_class::PLACEHOLDER)).to eq(%w[__P0001__ __P0002__])
    expect(unit.tokens.keys).to eq(%w[__P0001__ __P0002__])
    expect(unit.tokens.values).to eq(['Nihitam&#x301; guha&#x301;ya&#x301;m', 'guha&#x301;'])
  end

  it 'uses distinct placeholders for repeated protected values' do
    unit = batch.send(:prepare_unit, 'repeated-value', 'Dharma supports Dharma.')

    expect(unit.prepared).to eq('__P0001__ supports __P0002__.')
    expect(unit.tokens).to eq('__P0001__' => 'Dharma', '__P0002__' => 'Dharma')
  end

  it 'nests modifiers of repeated protected classification terms' do
    unit = batch.send(
      :prepare_unit, 'repeated-classification-term',
      'Thus, there are three dharmas &ndash; plant dharma, animal dharma and human dharma.'
    )

    expect(unit.prepared).to eq(
      'Thus, there are three dharmas &ndash; __P0001__, __P0002__ and __P0003__.'
    )
    expect(unit.tokens.values).to all(match(/\A⟦U[0-9a-f]{64}⟧ dharma\z/))
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('plant', 'animal', 'human')
  end

  it 'does not treat an encoded possessive suffix as a protected-term modifier' do
    unit = batch.send(
      :prepare_unit, 'possessive-protected-term',
      'The author&#146;s Ra&#x301;r&#x301;h: The Cradle of Civilization discusses Ra&#x301;r&#x301;h.'
    )

    expect(unit.prepared).to match(/The author's __P\d{4}__: The Cradle of Civilization/)
    expect(unit.tokens.values).to include('Ra&#x301;r&#x301;h')
    expect(unit.tokens.values).not_to include(a_string_matching(/⟦U[0-9a-f]{64}⟧ Ra&#x301;r&#x301;h/))
  end

  it 'nests definitions of coordinated protected terms' do
    unit = batch.send(
      :prepare_unit, 'coordinated-term-definitions',
      'Bhagavat Dharma has four aspects &ndash; vista&#x301;ra or expansion, rasa or flow, ' \
      'seva&#x301; or service and tadsthiti or attainment of the supreme stance.'
    )

    expect(unit.prepared).to eq(
      '__P0001__ has four aspects &ndash; __P0002__, __P0003__, __P0004__ and __P0005__.'
    )
    expect(unit.tokens.values_at('__P0002__', '__P0003__', '__P0004__', '__P0005__')).to all(
      match(/\A.+ ⟦U[0-9a-f]{64}⟧\z/)
    )
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'or expansion', 'or flow', 'or service', 'or attainment of the supreme stance'
    )
  end

  it 'nests parenthetical definitions of standalone foreign terms' do
    unit = batch.send(
      :prepare_unit, 'foreign-caste-definitions',
      'In ancient Bengal there were only two varn&#x301;as or castes: the vipras (intellectuals) ' \
      'and the shu&#x301;dras (labourers).'
    )

    expect(unit.prepared).to eq(
      'In ancient Bengal there were only two __P0001__: the __P0002__ and the __P0003__.'
    )
    expect(unit.tokens.values).to all(match(/⟦U[0-9a-f]{64}⟧/))
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'or castes', 'intellectuals', 'labourers'
    )
  end

  it 'resolves a protected gloss nested inside a larger protected inline token' do
    unit = batch.send(
      :prepare_unit, 'nested-protected-token',
      'The <i>na&#x301;gacampaka, na&#x301;geshvara [cobra flower], nandanacampaka</i> blooms.'
    )

    expect(unit.prepared).to eq('The __P0001__ blooms.')
    expect(unit.tokens.keys).to eq(['__P0001__'])
    expect(unit.tokens.fetch('__P0001__')).to match(
      /\A<i>na&#x301;gacampaka, na&#x301;geshvara \[⟦U[0-9a-f]{64}⟧\], nandanacampaka<\/i>\z/
    )
    expect(unit.tokens.values.join).not_to match(described_class::PLACEHOLDER)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('cobra flower')
  end

  it 'recursively resolves document protection inside double-bracketed glosses' do
    unit = batch.send(
      :prepare_unit, 'nested-document-protection',
      'People eat [[d&#x301;a&#x301;m&#x301;ga&#x301;r kalmii [land-growing kalmii],]] stems.'
    )

    protected = unit.tokens.values.join
    expect(protected).not_to match(described_class::PROTECTED_MARKER)
    expect(protected).to match(/\A\[\[⟦U[0-9a-f]{64}⟧\]\]\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('land-growing kalmii')
  end

  it 'resolves document protection before registering nested unit source' do
    protected = batch.send(:protect_content, '&rdquo; [&ldquo;to avenge&rdquo;]')
    marker = batch.send(
      :register_unit,
      "Pratividhitsite means &ldquo;Pratividha&#x301;n karte#{protected}."
    )
    unit = batch.instance_variable_get(:@units).fetch(marker.match(described_class::UNIT_MARKER)[1])

    expect(unit.source).to eq(
      'Pratividhitsite means &ldquo;Pratividha&#x301;n karte&rdquo; [&ldquo;to avenge&rdquo;].'
    )
    expect(unit.source).not_to match(described_class::DOCUMENT_MARKER)
    expect(
      batch.send(
        :restore_tokens, unit,
        'Pratividhitsite significa &ldquo;__P0001__ karte__P0002__.'
      )
    ).to eq(
      "Pratividhitsite significa &ldquo;#{unit.tokens.fetch('__P0001__')} " \
      "karte#{unit.tokens.fetch('__P0002__')}."
    )
  end

  it 'restores editorial brackets trapped inside a protected foreign inline token' do
    scientific_name = '<I>[Benincasa&#x301; cerifera Savi]</I>'
    unit = batch.send(
      :prepare_unit, 'bracketed-scientific-name',
      "The pumpkin #{scientific_name} has a different structure."
    )

    expect(unit.prepared).to eq('The pumpkin __P0001__ has a different structure.')
    expect(unit.tokens).to eq('__P0001__' => scientific_name)
    expect(unit.tokens.values.join).not_to include('⟦E')
  end

  it 'rejects translations that alter editorial brackets' do
    document, translations = prepare_translation(batch)
    rendered = batch.send(:render, document, translations).sub('[&ldquo;', '&ldquo;')

    expect { batch.send(:validate_structure!, source, rendered) }.to raise_error(/editorial brackets changed/)
  end

  it 'translates editorial content inline and restores its exact brackets' do
    unit = batch.send(:prepare_unit, 'editorial-inline', "He sees [the aspirant's] own mind.")

    expect(unit.prepared).to eq("He sees <span data-ewprs=\"11\">the aspirant's</span> own mind.")
    expect(
      batch.send(
        :restore_tokens, unit,
        'Ele vê a própria mente do <span data-ewprs="11">aspirante</span>.'
      )
    ).to eq('Ele vê a própria mente do [aspirante].')
  end

  it 'restores internal editorial markers in semantic unit source' do
    unit = batch.send(
      :prepare_unit, 'editorial-source',
      'The ⟦E11⟧nerve-cells⟦/E11⟧ come into play.'
    )

    expect(unit.source).to eq('The [nerve-cells] come into play.')
  end

  it 'translates long editorial notes as nested sentence units' do
    editorial = 'This long editorial note contains enough explanatory prose to require an independent ' \
                'translation unit instead of fragile inline markup around the entire note and its details.'
    unit = batch.send(:prepare_unit, 'long-editorial', "See [#{editorial}], by the author.")

    expect(unit.prepared).to eq('See __P0001__, by the author.')
    expect(unit.tokens.fetch('__P0001__')).to match(/\A\[⟦U[0-9a-f]{64}⟧\]\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(editorial)
  end

  it 'translates long editorial clauses as nested units' do
    editorial = 'the surasaptaka or seven notes in Western music, including its distinct octave structure'
    unit = batch.send(:prepare_unit, 'long-editorial-clause', "Music [#{editorial}] follows.")

    expect(unit.prepared).to eq('Music __P0001__ follows.')
    expect(unit.tokens.fetch('__P0001__')).to match(/\A\[⟦U[0-9a-f]{64}⟧\]\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(editorial)
  end

  it 'translates sentence-bearing editorial content as nested units' do
    unit = batch.send(
      :prepare_unit, 'sentence-editorial',
      'the centripetal [force. It also has two expressions &ndash;] one is'
    )

    expect(unit.prepared).to eq('the centripetal __P0001__ one is')
    expect(unit.tokens.fetch('__P0001__').scan(described_class::UNIT_MARKER).size).to eq(2)
    expect(unit.prepared).not_to include('data-ewprs')
  end

  it 'references one nested unit through distinct occurrence placeholders' do
    unit = batch.send(
      :prepare_unit, 'repeated-editorial',
      'Prakrti is the secondary [efficient cause], Purusa is the chief [efficient cause].'
    )

    expect(unit.prepared.scan(described_class::PLACEHOLDER)).to eq(
      %w[__P0001__ __P0002__ __P0003__ __P0004__]
    )
    nested = unit.tokens.values.select { |value| value.match?(described_class::UNIT_MARKER) }
    expect(nested.size).to eq(2)
    expect(nested.uniq.one?).to be(true)
    expect(nested.first).to match(/\A\[⟦U[0-9a-f]{64}⟧\]\z/)
    expect(unit.prepared).not_to include('data-ewprs')
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('efficient cause')
  end

  it 'translates unattached double-bracket insertions as nested units' do
    unit = batch.send(
      :prepare_unit, 'double-bracket-editorial',
      'The interpretation varies from [[that of]] philosophy.'
    )

    expect(unit.prepared).to eq('The interpretation varies from __P0001__ philosophy.')
    expect(unit.tokens.fetch('__P0001__')).to match(/\A\[\[⟦U[0-9a-f]{64}⟧\]\]\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('that of')
  end

  it 'translates bracketed compound adjectives as movable nested units' do
    unit = batch.send(:prepare_unit, 'compound-editorial', 'The Kayastha [upper-caste] boys arrived.')

    expect(unit.prepared).to eq('The Kayastha __P0001__ boys arrived.')
    expect(unit.tokens.fetch('__P0001__')).to match(/\A\[⟦U[0-9a-f]{64}⟧\]\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include('upper-caste')
  end

  it 'keeps a hyphen-attached editorial word with its translatable compound' do
    unit = batch.send(
      :prepare_unit, 'hyphenated-editorial',
      'This anxiety-[ridden] life needs relief.'
    )

    expect(unit.prepared).to eq(
      'This <span data-ewprs="11">anxiety-ridden</span> life needs relief.'
    )
    expect(
      batch.send(
        :restore_tokens, unit,
        'Esta vida <span data-ewprs="11">repleta de ansiedade</span> precisa de alívio.'
      )
    ).to eq('Esta vida [repleta de ansiedade] precisa de alívio.')
  end

  it 'keeps a directly attached editorial fragment with its word' do
    unit = batch.send(
      :prepare_unit, 'attached-editorial',
      'Living on this world we can[[not]] be apathetic.'
    )

    expect(unit.prepared).to eq(
      'Living on this world we <span data-ewprs="22">cannot</span> be apathetic.'
    )
    expect(
      batch.send(
        :restore_tokens, unit,
        'Vivendo neste mundo, <span data-ewprs="22">não podemos</span> ser apáticos.'
      )
    ).to eq('Vivendo neste mundo, [[não podemos]] ser apáticos.')
  end

  it 'rejects translations that alter editorial translation tags' do
    unit = batch.send(:prepare_unit, 'editorial-tag', 'English [editorial] sentence.')

    expect { batch.send(:restore_tokens, unit, 'Português editorial sentence.') }
      .to raise_error(/changed editorial tags/)
  end

  it 'projects dropped or partial editorial tags onto a unique translated phrase' do
    translator = FakeMarkupTranslator.new do |text|
      {'Is' => 'Es', 'ancestral lineage' => 'linaje ancestral'}.fetch(text, text)
    end
    batch = described_class.new(root: root, target: 'es', cache: cache, translator: translator)
    unit = batch.send(:prepare_unit, 'editorial-alignment', '[Is] idol worship?')
    partial = batch.send(:prepare_unit, 'partial-editorial-alignment', '[ancestral lineage] name.')

    expect(
      batch.send(:restore_tokens_with_retries, unit, '¿El culto a los ídolos también es?')
    ).to eq('¿El culto a los ídolos también [es]?')
    expect(
      batch.send(
        :restore_tokens_with_retries, partial,
        'linaje ancestral <span data-ewprs="11"> nombre.'
      )
    ).to eq('[linaje ancestral] nombre.')
    expect(translator.repair_calls).to be_empty
  end

  it 'retranslates editorial segments when phrase projection cannot align them' do
    unit = described_class::Unit.new(
      key: 'editorial-segment-projection',
      source: 'The Sanskrit dhya&#x301;na became c&#146;han [in Chinese], then chen [in Korean].',
      prepared: 'The Sanskrit __P0001__ became c\'han <span data-ewprs="11">in Chinese</span>, ' \
                'then chen <span data-ewprs="11">in Korean</span>.',
      tokens: {'__P0001__' => 'dhya&#x301;na'}, leading: '', trailing: ''
    )
    malformed = 'Das Sanskrit __P0001__ wurde im Chinesischen zu c\'han ' \
                '<span data-ewprs="11">, dann im Koreanischen zu chen <span data-ewprs="11">.</span>'
    projected = 'Das Sanskrit __P0001__ wurde c\'han <span data-ewprs="11">auf Chinesisch</span>, ' \
                'dann chen <span data-ewprs="11">auf Koreanisch</span>.'
    translator = instance_double(Ewprs::Translator)
    allow(translator).to receive(:translate_markup).with(['in Chinese'], from: 'en', to: 'de')
      .and_return(['auf Chinesisch'])
    expect(translator).to receive(:translate_preserving_editorial_tags).with(
      unit.prepared, from: 'en', to: 'de'
    ).and_return(projected)
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator)

    expect(batch.send(:restore_tokens_with_retries, unit, malformed)).to eq(
      'Das Sanskrit dhya&#x301;na wurde c&#39;han [auf Chinesisch], dann chen [auf Koreanisch].'
    )
  end

  it 'falls back to bounded repair when editorial projection remains invalid' do
    unit = described_class::Unit.new(
      key: 'editorial-projection-scope', source: 'Music [the seven notes] <i>term</i>.',
      prepared: 'Music <span data-ewprs="11">the seven notes</span> __P0001__term__P0002__.',
      tokens: {'__P0001__' => '<i>', '__P0002__' => '</i>'}, leading: '', trailing: ''
    )
    valid = 'Música <span data-ewprs="11">as sete notas</span> __P0001__termo__P0002__.'
    translator = FakeMarkupTranslator.new do |text|
      text == 'the seven notes' ? 'as sete notas' : valid
    end
    batch = described_class.new(root: root, target: 'pt', cache: cache, translator: translator)

    expect(
      batch.send(
        :restore_tokens_with_retries, unit,
        'Música __P0001__termo__P0002__ as sete notas.'
      )
    ).to eq('Música [as sete notas] <i>termo</i>.')
    expect(translator.repair_calls.size).to eq(1)
  end

  it 'keeps complete footnotes out of model input' do
    document, translations = prepare_translation(batch)
    rendered = batch.send(:render, document, translations)

    expect(translator.calls.join).not_to include('Ref.fn2')
    expect(rendered).to include(
      '<!-- fn --><a name="Ref.fn2"></a><sup>(<b><a href="#fn2">2</a></b>)</sup><!-- /fn -->'
    )
  end

  it 'keeps empty inline elements out of model input' do
    template = batch.send(:register_content, 'English before <I></I>English after.')
    units = batch.instance_variable_get(:@units).values

    expect(units.map(&:prepared)).to eq(['English before', 'English after.'])
    expect(template).to match(/\A⟦U[0-9a-f]{64}⟧ <I><\/I>⟦U[0-9a-f]{64}⟧\z/)
  end

  it 'translates prose around a protected element' do
    prepare_translation(batch)
    call = translator.calls.find { |text| text.include?('English before') && text.include?('English after') }

    expect(call).to match(/English before __P\d{4}__ English after\./)
  end

  it 'resumes from the persistent unit cache' do
    prepare_translation(batch)
    resumed_translator = FakeMarkupTranslator.new { raise 'cache miss' }
    resumed = described_class.new(
      root: root, cache: cache, translator: resumed_translator, stdout: StringIO.new
    )

    prepare_translation(resumed)

    expect(resumed_translator.calls).to be_empty
  end

  it 'discards and replaces an invalid cached translation' do
    prepare_translation(batch)
    unit = batch.instance_variable_get(:@units).values.find { |value| value.source == 'English plain sentence.' }
    JsonlStore.new(cache).append(key: unit.key, translation: unit.source, at: Time.now.utc.iso8601)
    resumed_translator = FakeMarkupTranslator.new
    resumed = described_class.new(
      root: root, cache: cache, translator: resumed_translator, stdout: StringIO.new
    )

    prepare_translation(resumed)

    expect(resumed_translator.calls).to eq(['English plain sentence.'])
  end

  it 'discards a cached translation with stale nested unit markers' do
    prepare_translation(batch)
    unit = batch.instance_variable_get(:@units).values.find { |value| value.source == 'English plain sentence.' }
    stale_marker = "⟦U#{'0' * 64}⟧"
    JsonlStore.new(cache).append(
      key: unit.key, translation: "Português #{stale_marker}.", at: Time.now.utc.iso8601
    )
    resumed_translator = FakeMarkupTranslator.new
    resumed = described_class.new(
      root: root, cache: cache, translator: resumed_translator, stdout: StringIO.new
    )

    prepare_translation(resumed)

    expect(resumed_translator.calls).to eq(['English plain sentence.'])
  end

  it 'rejects a restored translation with reordered HTML tags' do
    unit = described_class::Unit.new(
      key: 'cached-markup', source: '<i>English term</i>',
      prepared: '__P0001__English term__P0002__',
      tokens: {'__P0001__' => '<i>', '__P0002__' => '</i>'},
      leading: '', trailing: ''
    )

    expect do
      batch.send(:validate_restored_translation!, unit, '</i>Termo em português<i>')
    end.to raise_error(Ewprs::TranslationValidator::Error, /changed HTML tag sequence/)
  end

  it 'allows balanced reordering of inline emphasis tags' do
    source = '<p><i>first</i> and <i>second</i></p>'
    translated = '<p><i>second</i> e <i>first</i></p>'

    expect { batch.send(:validate_structure!, source, translated) }.not_to raise_error
  end

  it 'rejects unbalanced inline tags when the source markup is balanced' do
    source = '<p><i>first</i> and <i>second</i></p>'
    translated = '<p></i>second<i> e <i>first</i></p>'

    expect { batch.send(:validate_structure!, source, translated) }
      .to raise_error(/HTML structure changed/)
  end

  it 'rejects changed nesting of balanced inline tags' do
    source = '<p><i>first</i> and <i>second</i> and <i>third</i></p>'
    translated = '<p><i>first <i>second</i> and third</i></p>'

    expect { batch.send(:validate_structure!, source, translated) }
      .to raise_error(/HTML structure changed/)
  end

  it 'preserves the source file mode when writing a translated document' do
    path = File.join(root, 'HTML/Discourses/Mode.html')
    File.binwrite(path, 'source')
    document = described_class::Document.new(
      entry: described_class::Entry.new(kind: :discourse, path: path),
      encoding: Encoding::UTF_8,
      mode: 0o755
    )

    batch.send(:write_document, document, 'translated')

    expect(File.stat(path).mode & 0o7777).to eq(0o755)
  end

  it 'promotes legacy output encoding when target text is not representable' do
    path = File.join(root, 'HTML/Discourses/Chinese.html')
    File.binwrite(path, 'source')
    document = described_class::Document.new(
      entry: described_class::Entry.new(kind: :discourse, path: path),
      encoding: Encoding::Windows_1252,
      mode: 0o644
    )

    batch.send(:write_document, document, '<p>中文</p>')

    output = File.binread(path).force_encoding(Encoding::UTF_8)
    expect(output.valid_encoding?).to be(true)
    expect(output).to include('中文')
  end

  it 'protects a foreign inline phrase as one immutable token' do
    unit = batch.send(:prepare_unit, 'foreign-inline', 'The phrase <i>praka&#x301;ram&#x301; karoti iti</i> is used.')

    expect(unit.prepared).to eq('The phrase __P0001__ is used.')
    expect(unit.tokens).to eq('__P0001__' => '<i>praka&#x301;ram&#x301; karoti iti</i>')
  end

  it 'protects a single-word foreign inline element as one immutable token' do
    unit = batch.send(:prepare_unit, 'single-word-foreign-inline', '[How many <i>bauls</i>')

    expect(unit.prepared).to eq('__P0001__How many __P0002__')
    expect(unit.tokens).to eq('__P0001__' => '[', '__P0002__' => '<i>bauls</i>')
  end

  it 'rejects translations that alter protected tokens' do
    broken = FakeMarkupTranslator.new do |text|
      text.gsub('English', 'Português').gsub('Translate me', 'Traduza-me').gsub(/\band\b/, 'e')
        .sub(/__P\d{4}__/, '')
    end
    output = StringIO.new
    invalid = described_class.new(root: root, cache: cache, translator: broken, stdout: output)
    entry = described_class::Entry.new(kind: :discourse, path: File.join(root, 'HTML/Discourses/Complete.html'))
    invalid.send(:prepare_documents, [entry])

    expect { invalid.send(:translate_units) }.to raise_error(/changed protected tokens.*missing:/)
    expect(output.string).to include(
      'failed invalid translation', 'source: ', 'prepared: ', 'output: '
    )
  end

  it 'removes surplus protected-token occurrences without model repair' do
    unit = described_class::Unit.new(
      key: 'duplicated-token', source: 'English term and prose.',
      prepared: 'English __P0001__ and prose.', tokens: {'__P0001__' => 'term'},
      leading: '', trailing: ''
    )

    expect(
      batch.send(
        :restore_tokens_with_retries, unit,
        'Português __P0001__ e __P0001__ prosa.'
      )
    ).to eq('Português term e prosa.')
    expect(translator.repair_calls).to be_empty
  end

  it 'retranslates marker failures with XML placeholder transport' do
    unit = described_class::Unit.new(
      key: 'transport-marker', source: 'The term appears.', prepared: 'The __P0001__ appears.',
      tokens: {'__P0001__' => 'term'},
      leading: '', trailing: ''
    )
    translator = instance_double(Ewprs::Translator)
    expect(translator).to receive(:translate_preserving_placeholders).with(
      unit.prepared, values: {'__P0001__' => 'term'}, from: 'en', to: 'pt'
    ).and_return('O __P0001__ aparece.')
    batch = described_class.new(root: root, target: 'pt', cache: cache, translator: translator)

    expect(batch.send(:restore_tokens_with_retries, unit, 'O ZXQEWPRSP aparece.')).to eq('O term aparece.')
  end

  it 'restores a uniquely transliterated protected term to its exact source form' do
    unit = described_class::Unit.new(
      key: 'transliterated-token', source: 'The natural Pra&#x301;n&#x301;a Dharma remains.',
      prepared: 'The natural __P0001__ remains.',
      tokens: {'__P0001__' => 'Pra&#x301;n&#x301;a Dharma'}, leading: '', trailing: ''
    )

    expect(
      batch.send(
        :restore_tokens_with_retries, unit,
        'Das natürliche Prana Dharma bleibt bestehen.'
      )
    ).to eq('Das natürliche Pra&#x301;n&#x301;a Dharma bleibt bestehen.')
    expect(translator.repair_calls).to be_empty
  end

  it 'reprojects exact protected values expanded by the model' do
    unit = described_class::Unit.new(
      key: 'expanded-values',
      source: 'The word is very [[close]] to the English word &ldquo;near&rdquo;.',
      prepared: 'The word is very __P0001__ to the English word __P0002__.',
      tokens: {'__P0001__' => '[[close]]', '__P0002__' => '&ldquo;near&rdquo;'},
      leading: '', trailing: ''
    )

    expect(
      batch.send(
        :restore_tokens_with_retries, unit,
        'Das Wort ist sehr [[close]] zum englischen Wort &ldquo;near&rdquo;.'
      )
    ).to eq('Das Wort ist sehr [[close]] zum englischen Wort &ldquo;near&rdquo;.')
    expect(translator.repair_calls).to be_empty
  end

  it 'uses XML placeholder projection when placeholder-heavy output is untranslated' do
    unit = described_class::Unit.new(
      key: 'untranslated-placeholders',
      source: 'Karana Brahma in Tantric scriptures by all the svaravarna sounds taken together.',
      prepared: '__P0001__ __P0002__ in Tantric scriptures by all the __P0003__ sounds taken together.',
      tokens: {'__P0001__' => 'Karana', '__P0002__' => 'Brahma', '__P0003__' => 'svaravarna'},
      leading: '', trailing: ''
    )
    translator = instance_double(Ewprs::Translator)
    expect(translator).to receive(:translate_preserving_placeholders).with(
      unit.prepared,
      values: {'__P0001__' => 'Karana', '__P0002__' => 'Brahma', '__P0003__' => 'svaravarna'},
      from: 'en', to: 'de'
    ).and_return('__P0001__ __P0002__ in tantrischen Schriften durch alle __P0003__ Klänge zusammen.')
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator)

    expect(
      batch.send(:restore_tokens_with_retries, unit, unit.prepared)
    ).to eq('Karana Brahma in tantrischen Schriften durch alle svaravarna Klänge zusammen.')
  end

  it 'restores a natural-text projection when XML transport leaves entity-heavy prose untranslated' do
    unit = described_class::Unit.new(
      key: 'natural-placeholder-projection',
      source: 'Hiran&#x301;maya Kos&#x301;a &ndash; in this kos&#x301;a the body even the knowledge of ' \
              '&ldquo;I&rdquo; is not much in evidence.',
      prepared: '__P0001__ &ndash; in this __P0002__ the body even the knowledge of ' \
                '&ldquo;I&rdquo; is not much in evidence.',
      tokens: {'__P0001__' => 'Hiran&#x301;maya Kos&#x301;a', '__P0002__' => 'kos&#x301;a'},
      leading: '', trailing: ''
    )
    translator = instance_double(Ewprs::Translator)
    expect(translator).to receive(:translate_preserving_placeholders).with(
      unit.prepared,
      values: {'__P0001__' => 'Hiran&#x301;maya Kos&#x301;a', '__P0002__' => 'kos&#x301;a'},
      from: 'en', to: 'de'
    ).and_return(
      '__P0001__ &ndash; in dieser __P0002__ sind der Körper und das Wissen vom ' \
      '&ldquo;Ich&rdquo; kaum erkennbar.'
    )
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator)

    expect(
      batch.send(:restore_tokens_with_retries, unit, unit.prepared)
    ).to eq(
      'Hiran&#x301;maya Kos&#x301;a &ndash; in dieser kos&#x301;a sind der Körper und das Wissen vom ' \
      '&ldquo;Ich&rdquo; kaum erkennbar.'
    )
  end

  it 'retranslates quote-separated clauses when one drops a protected token' do
    unit = described_class::Unit.new(
      key: 'quoted-token', source: 'Go to Kashi.&rdquo; And &ldquo;Return to Kashi.',
      prepared: 'Go to __P0001__.&rdquo; And &ldquo;Return to __P0002__.',
      tokens: {'__P0001__' => 'Kashi', '__P0002__' => 'Kashi'}, leading: '', trailing: ''
    )
    translator = instance_double(Ewprs::Translator)
    expect(translator).to receive(:translate_preserving_smart_quotes).and_return(
      'Geh nach __P0001__.&rdquo; Und &ldquo;Kehre nach __P0002__ zurück.'
    )
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator)

    expect(
      batch.send(
        :restore_tokens_with_retries, unit,
        'Geh nach __P0001__.&rdquo; Und &ldquo;Kehre zurück.'
      )
    ).to eq('Geh nach Kashi.&rdquo; Und &ldquo;Kehre nach Kashi zurück.')
  end

  it 'retranslates quoted segments when an entity-heavy title is left untranslated' do
    source = 'EE7.5 - &ldquo;Caraeveti Caraeveti&rdquo; &ndash; &ldquo;Move On, Move On&rdquo;'
    prepared = '__P0001__ - &ldquo;Caraeveti Caraeveti&rdquo; &ndash; &ldquo;Move On, Move On&rdquo;'
    unit = described_class::Unit.new(
      key: 'untranslated-quoted-title', source: source, prepared: prepared,
      tokens: {'__P0001__' => 'EE7.5'}, leading: '', trailing: ''
    )
    translator = instance_double(Ewprs::Translator)
    expect(translator).to receive(:translate_preserving_placeholders).with(
      prepared, values: {'__P0001__' => 'EE7.5'}, from: 'en', to: 'de'
    ).and_return(prepared)
    expect(translator).to receive(:translate_preserving_smart_quotes).with(
      prepared, from: 'en', to: 'de'
    ).and_return(
      '__P0001__ - &ldquo;Caraeveti Caraeveti&rdquo; &ndash; &ldquo;Mach weiter, mach weiter&rdquo;'
    )
    expect(translator).not_to receive(:repair_markup)
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator)

    expect(batch.send(:restore_tokens_with_retries, unit, prepared)).to eq(
      'EE7.5 - &ldquo;Caraeveti Caraeveti&rdquo; &ndash; &ldquo;Mach weiter, mach weiter&rdquo;'
    )
  end

  it 'allows adjacent quoted terms after restoring a protected quotation' do
    unit = described_class::Unit.new(
      key: 'adjacent-restored-quotes',
      source: 'The word &ldquo;Ra&#x301;ma&rdquo; is &ldquo;the attractive faculty&rdquo;.',
      prepared: 'The word __P0001__ is &ldquo;the attractive faculty&rdquo;.',
      tokens: {'__P0001__' => '&ldquo;Ra&#x301;ma&rdquo;'}, leading: '', trailing: ''
    )
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator)

    expect(
      batch.send(
        :restore_tokens_with_retries, unit,
        'Die Bedeutung ist beim Wort __P0001__ &ldquo;die anziehende Fähigkeit&rdquo;.'
      )
    ).to eq(
      'Die Bedeutung ist beim Wort &ldquo;Ra&#x301;ma&rdquo; &ldquo;die anziehende Fähigkeit&rdquo;.'
    )
  end

  it 'retranslates partially translated entity-heavy prose with natural punctuation' do
    source = 'And whatever I would offer, such as flowers, garlands, sandal paste, whatever I want to offer ' \
             'you &ndash; all of those things have been created by you.'
    unit = described_class::Unit.new(
      key: 'partial-entity-translation', source: source, prepared: source,
      tokens: {}, leading: '', trailing: ''
    )
    translator = instance_double(Ewprs::Translator)
    expect(translator).to receive(:translate_preserving_character_references).with(
      source, from: 'en', to: 'de'
    ).and_return(
      'Und alles, was ich anbieten würde, wie Blumen, Kränze und Sandelpaste &ndash; all diese Dinge wurden ' \
      'von dir geschaffen.'
    )
    expect(translator).not_to receive(:repair_markup)
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator)

    expect(
      batch.send(
        :restore_tokens_with_retries, unit,
        'Und whatever I would offer, such as flowers, garlands, sandal paste, whatever I want to offer you ' \
        '&ndash; all of those things have been created by you.'
      )
    ).to eq(
      'Und alles, was ich anbieten würde, wie Blumen, Kränze und Sandelpaste &ndash; all diese Dinge wurden ' \
      'von dir geschaffen.'
    )
  end

  it 'retranslates an echoed comma-dense fragment by clauses' do
    source = 'So in that first figure, in that first geometrical figure, at the dawn of creation, ' \
             'there may be more than one line,'
    unit = described_class::Unit.new(
      key: 'comma-dense-fragment', source: source, prepared: source,
      tokens: {}, leading: '', trailing: ''
    )
    translator = instance_double(Ewprs::Translator)
    expect(translator).to receive(:translate_by_clauses).with(
      source, from: 'en', to: 'de'
    ).and_return(
      'So in jener ersten Figur, in dieser ersten geometrischen Figur, zu Beginn der Schöpfung, ' \
      'es kann mehr als eine Zeile geben,'
    )
    expect(translator).not_to receive(:repair_markup)
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator)

    expect(batch.send(:restore_tokens_with_retries, unit, source)).to eq(
      'So in jener ersten Figur, in dieser ersten geometrischen Figur, zu Beginn der Schöpfung, ' \
      'es kann mehr als eine Zeile geben,'
    )
  end

  it 'retranslates retained bibliographic words by clauses around placeholders' do
    prepared = 'Third publication as __P0001__, Third Edition, 1987.'
    unit = described_class::Unit.new(
      key: 'bibliographic-clauses', source: 'Third publication as a title, Third Edition, 1987.',
      prepared: prepared, tokens: {'__P0001__' => 'a title'}, leading: '', trailing: ''
    )
    translator = instance_double(Ewprs::Translator)
    expect(translator).to receive(:translate_by_clauses).with(
      prepared, from: 'en', to: 'de'
    ).and_return('Dritte Veröffentlichung als __P0001__, Dritte Auflage, 1987.')
    expect(translator).not_to receive(:repair_markup)
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator)

    expect(
      batch.send(
        :restore_tokens_with_retries, unit,
        'Dritte Veröffentlichung als __P0001__, Third Edition, 1987.'
      )
    ).to eq('Dritte Veröffentlichung als a title, Dritte Auflage, 1987.')
  end

  it 'reprojects delimiter-bearing placeholders when translation changes their order' do
    unit = described_class::Unit.new(
      key: 'delimiter-placeholder-order',
      source: 'Besides, sauna [a note], a man who (through death or divorce) lost his wife lives in Rarh.',
      prepared: 'Besides, __P0001__, a man who __P0002__ lost his wife lives in __P0003__.',
      tokens: {
        '__P0001__' => 'sauna [a note]', '__P0002__' => '(through death or divorce)', '__P0003__' => 'Rarh'
      },
      leading: '', trailing: ''
    )
    translator = instance_double(Ewprs::Translator)
    expect(translator).to receive(:translate_preserving_placeholders).with(
      unit.prepared, values: unit.tokens, from: 'en', to: 'de'
    ).and_return(
      'Außerdem lebt __P0001__, ein Mann, der __P0002__ seine Frau verloren hat, in __P0003__.'
    )
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator)

    expect(
      batch.send(
        :restore_tokens_with_retries, unit,
        'Außerdem lebt in __P0003__ ein Mann, der __P0002__ seine Frau verloren hat, ebenso wie __P0001__.'
      )
    ).to eq(
      'Außerdem lebt sauna [a note], ein Mann, der (through death or divorce) seine Frau verloren hat, in Rarh.'
    )
  end

  it 'removes balanced delimiters introduced around translated prose' do
    unit = described_class::Unit.new(
      key: 'introduced-delimiters', source: 'Bengali: Pakur&#x301;.', prepared: 'Bengali: __P0001__.',
      tokens: {'__P0001__' => 'Pakur&#x301;'}, leading: '', trailing: ''
    )
    arabic = described_class.new(root: root, target: 'ar', cache: cache, translator: translator)

    expect(
      arabic.send(:restore_tokens_with_retries, unit, 'البنغالية (__P0001__).')
    ).to eq('البنغالية Pakur&#x301;.')
    expect(translator.repair_calls).to be_empty
  end

  it 'attempts smart-quote projection only once before bounded repair' do
    unit = described_class::Unit.new(
      key: 'quoted-loop', source: 'English &ldquo;quotation&rdquo;.',
      prepared: 'English &ldquo;quotation&rdquo;.', tokens: {}, leading: '', trailing: ''
    )
    translator = instance_double(Ewprs::Translator)
    allow(translator).to receive(:translate_preserving_smart_quotes).and_return('Deutsches &ldquo;Zitat&rdquo;.')
    allow(translator).to receive(:repair_markup).and_return('Weiterhin ungültig.')
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator, stdout: StringIO.new)
    allow(batch.validator).to receive(:validate!).and_raise(
      Ewprs::TranslationValidator::Error.new(:quotes, 'translation changed smart quotes')
    )

    expect do
      batch.send(:restore_tokens_with_retries, unit, 'Ungültige &ldquo;Übersetzung&rdquo;.')
    end.to raise_error(Ewprs::TranslationValidator::Error, /changed smart quotes/)
    expect(translator).to have_received(:translate_preserving_smart_quotes).once
    expect(translator).to have_received(:repair_markup).exactly(described_class::TOKEN_RETRIES).times
  end

  it 'restores batch translations concurrently up to translator jobs' do
    translator = instance_double(Ewprs::Translator, jobs: 2)
    allow(translator).to receive(:translate_markup) { |texts, **| texts.map { |text| "translated #{text}" } }
    batch = described_class.new(root: root, target: 'de', cache: cache, translator: translator, stdout: StringIO.new)
    units = %w[first second].to_h do |key|
      [key, described_class::Unit.new(key: key, source: key, prepared: key, tokens: {}, leading: '', trailing: '')]
    end
    batch.instance_variable_set(:@units, units)
    allow(batch).to receive(:validated_cached_translations).and_return({})
    allow(batch).to receive(:cached_translations).and_return({})
    active = 0
    maximum = 0
    mutex = Mutex.new
    allow(batch).to receive(:restore_tokens_with_retries) do |unit, output|
      mutex.synchronize do
        active += 1
        maximum = [maximum, active].max
      end
      sleep 0.05
      "#{output} restored"
    ensure
      mutex.synchronize { active -= 1 }
    end

    expect(batch.send(:translate_units).values).to contain_exactly(
      'translated first restored', 'translated second restored'
    )
    expect(maximum).to eq(2)
  end

  it 'recovers from repeated transient protected-token corruption' do
    corruptions = 0
    flaky = FakeMarkupTranslator.new do |text|
      if corruptions < 3 && text.match?(/__P\d{4}__/)
        corruptions += 1
        text.sub(/__P\d{4}__/, '')
      else
        text.gsub('English', 'Português').gsub('Translate me', 'Traduza-me').gsub(/\band\b/, 'e')
      end
    end
    retried = described_class.new(root: root, cache: cache, translator: flaky, stdout: StringIO.new)

    expect { prepare_translation(retried) }.not_to raise_error
    expect(corruptions).to eq(3)
  end

  it 'includes nested source text in repair token meanings' do
    nested_marker = batch.send(:register_unit, 'the headquarters of Ananda Marga')
    tokens = {'__P0001__' => "(#{nested_marker})"}

    expect(batch.send(:repair_token_values, tokens)).to eq(
      '__P0001__' => '(the headquarters of Ananda Marga)'
    )
  end

  it 'keeps nested unit meanings out of protected placeholder projections' do
    nested_marker = batch.send(:register_unit, 'Horse Sacrifice')
    tokens = {
      '__P0001__' => "(#{nested_marker})",
      '__P0002__' => "Yajin&#x32D;a [#{nested_marker}]",
      '__P0003__' => 'Ra&#x301;jasu&#x301;ya'
    }

    expect(batch.send(:placeholder_projection_values, tokens)).to eq(
      '__P0001__' => '',
      '__P0002__' => 'Yajin&#x32D;a []',
      '__P0003__' => 'Ra&#x301;jasu&#x301;ya'
    )
  end

  it 'reprojects a transliterated outer term that carries a nested gloss' do
    chinese = described_class.new(
      root: root, target: 'zh', cache: cache, translator: translator, stdout: StringIO.new
    )
    nested_marker = chinese.send(:register_unit, 'mental reactive momenta')
    unit = described_class::Unit.new(
      key: 'nested-transliterated-token', prepared: 'its __P0001__',
      tokens: {'__P0001__' => "sam&#x301;ska&#x301;ras [#{nested_marker}]"}
    )

    expect(chinese.send(:project_missing_transliterated_tokens, unit, '自身的samskaras')).to eq(
      '自身的__P0001__'
    )
  end

  it 'distinguishes structural nested editorials from movable parentheticals' do
    nested_marker = batch.send(:register_unit, 'not')

    expect(batch.send(:structural_token?, "[[#{nested_marker}]]")).to be(true)
    expect(batch.send(:structural_token?, "(#{nested_marker})")).to be(false)
  end

  it 'uses ordered projection when a nested editorial moves past a parenthetical' do
    nested_marker = batch.send(:register_unit, 'not')
    unit = described_class::Unit.new(
      key: 'nested-editorial-order', source: 'It is [[not]] beyond time (Kalatiita).',
      prepared: 'It is __P0001__ beyond time __P0002__.',
      tokens: {'__P0001__' => "[[#{nested_marker}]]", '__P0002__' => '(Kalatiita)'},
      leading: '', trailing: ''
    )
    translator = instance_double(Ewprs::Translator)
    expect(translator).to receive(:translate_preserving_placeholder_order).with(
      unit.prepared, from: 'en', to: 'zh'
    ).and_return('它__P0001__超越时间__P0002__。')
    chinese = described_class.new(root: root, target: 'zh', cache: cache, translator: translator)
    chinese.instance_variable_get(:@units)[nested_marker[/[0-9a-f]{64}/]] =
      batch.instance_variable_get(:@units).fetch(nested_marker[/[0-9a-f]{64}/])

    expect(
      chinese.send(:restore_tokens_with_retries, unit, '它超越时间__P0002__。__P0001__')
    ).to eq("它[[#{nested_marker}]]超越时间(Kalatiita)。")
  end

  it 'allows protected terms to follow target-language grammar' do
    unit = described_class::Unit.new(
      key: 'terms', prepared: '__P0001__ __P0002__',
      tokens: {'__P0001__' => 'Daks&#x301;a', '__P0002__' => 'yajin&#x32D;a'},
      leading: '', trailing: ''
    )

    expect(batch.send(:restore_tokens, unit, '__P0002__ de __P0001__')).to eq(
      'yajin&#x32D;a de Daks&#x301;a'
    )
  end

  it 'restores lexical spacing after a protected marked term' do
    unit = described_class::Unit.new(
      key: 'term-boundary', source: 'ks&#x301;atriyas were born',
      prepared: '__P0001__ were born', tokens: {'__P0001__' => 'ks&#x301;atriyas'},
      leading: '', trailing: ''
    )

    expect(batch.send(:restore_tokens, unit, '__P0001__nasceram')).to eq(
      'ks&#x301;atriyas nasceram'
    )
  end

  it 'restores source spacing dropped between adjacent protected terms' do
    unit = described_class::Unit.new(
      key: 'adjacent-term-boundary', prepared: '__P0001__ __P0002__',
      tokens: {'__P0001__' => 'Ra&#x301;jasu&#x301;ya', '__P0002__' => 'Yajin&#x32D;a'},
      leading: '', trailing: ''
    )

    expect(batch.send(:normalize_protected_boundaries, unit, '__P0001____P0002__')).to eq(
      '__P0001__ __P0002__'
    )
  end

  it 'does not duplicate punctuation carried by a protected title' do
    unit = described_class::Unit.new(
      key: 'title-punctuation', source: 'appeared in <I>A Title,</I> and continued.',
      prepared: 'appeared in __P0001__ and continued.',
      tokens: {'__P0001__' => '<I>A Title,</I>'}, leading: '', trailing: ''
    )

    expect(batch.send(:restore_tokens, unit, 'apareció en __P0001__, y continuó.')).to eq(
      'apareció en <I>A Title,</I> y continuó.'
    )
  end

  it 'does not insert Latin spacing into non-Latin target text' do
    chinese = described_class.new(
      root: root, target: 'zh', cache: cache, translator: translator, stdout: StringIO.new
    )
    unit = described_class::Unit.new(
      key: 'chinese-term-boundary', source: 'This is Brahma.',
      prepared: 'This is __P0001__.', tokens: {'__P0001__' => 'Brahma'},
      leading: '', trailing: ''
    )

    expect(chinese.send(:normalize_protected_boundaries, unit, '这是__P0001__概念')).to eq(
      '这是__P0001__概念'
    )
  end

  it 'allows complete protected inline elements to follow target-language grammar' do
    unit = described_class::Unit.new(
      key: 'inline-elements', prepared: '__P0001__ before __P0002__',
      tokens: {'__P0001__' => '<i>Rgveda</i>', '__P0002__' => '<i>man&#x301;d&#x301;ala</i>'},
      leading: '', trailing: ''
    )

    expect(batch.send(:restore_tokens, unit, '__P0002__ do __P0001__')).to eq(
      '<i>man&#x301;d&#x301;ala</i> do <i>Rgveda</i>'
    )
  end

  it 'allows intact inline tag pairs to follow target-language grammar' do
    unit = described_class::Unit.new(
      key: 'inline-pairs',
      prepared: 'the __P0001__antahstha__P0002__ letter __P0003__ra__P0004__',
      tokens: {
        '__P0001__' => '<I>', '__P0002__' => '</I>',
        '__P0003__' => '<I>', '__P0004__' => '</I>'
      },
      leading: '', trailing: ''
    )

    expect(batch.send(
      :restore_tokens, unit, 'a letra __P0003__ra__P0004__ do __P0001__antahstha__P0002__'
    )).to eq('a letra <I>ra</I> do <I>antahstha</I>')
  end

  it 'rejects reordered structural tokens' do
    unit = described_class::Unit.new(
      key: 'markup', prepared: '__P0001__English__P0002__',
      tokens: {'__P0001__' => '<i>', '__P0002__' => '</i>'},
      leading: '', trailing: ''
    )

    expect { batch.send(:restore_tokens, unit, '__P0002__Português__P0001__') }
      .to raise_error(/reordered structural tokens/)
  end

  it 'rejects reversed paired-delimiter tokens before restoration' do
    unit = described_class::Unit.new(
      key: 'paired-delimiters', source: 'English (gloss).',
      prepared: 'English __P0001__gloss__P0002__.',
      tokens: {'__P0001__' => '(', '__P0002__' => ')'}, leading: '', trailing: ''
    )

    expect { batch.send(:restore_tokens, unit, 'Português __P0002__glosa__P0001__.') }
      .to raise_error(/reordered structural tokens/)
  end

  it 'rejects whitespace inserted between adjacent editorial brackets' do
    unit = described_class::Unit.new(
      key: 'double-bracket', source: 'In the days of Manu,[[',
      prepared: 'In the days of Manu,__P0001____P0001__',
      tokens: {'__P0001__' => '['}, leading: '', trailing: ''
    )

    expect { batch.send(:restore_tokens, unit, 'Nos tempos de Manu, __P0001__ __P0001__') }
      .to raise_error(/reordered structural tokens/)
    expect(batch.send(:restore_tokens, unit, 'Nos tempos de Manu, __P0001____P0001__')).to eq(
      'Nos tempos de Manu, [['
    )
  end

  it 'rejects editorial boundaries moved across structural tokens' do
    unit = described_class::Unit.new(
      key: 'editorial-scope',
      prepared: 'Music <span data-ewprs="11">the seven notes</span> __P0001____P0002__',
      tokens: {'__P0001__' => '(', '__P0002__' => 'term [gloss]'},
      leading: '', trailing: ''
    )

    expect do
      batch.send(
        :restore_tokens, unit,
        'Música <span data-ewprs="11">as sete notas __P0001____P0002__</span>'
      )
    end.to raise_error(/changed editorial tags/)
  end

  it 'allows a complete inline pair to move around an editorial citation' do
    unit = described_class::Unit.new(
      key: 'movable-inline-citation',
      prepared: 'agent <span data-ewprs="11">acidic coagulator</span> like ' \
                '__P0001__dadhyamla__P0002__',
      tokens: {'__P0001__' => '<I>', '__P0002__' => '</I>'}
    )
    translated = 'like __P0001__dadhyamla__P0002__这样的特定试剂<span data-ewprs="11">酸性凝固剂</span>'

    expect(batch.send(:valid_editorial_structure?, unit, translated)).to be(true)
  end

  it 'allows nested editorial units to reorder around an editorial citation' do
    first = batch.send(:register_unit, 'offered')
    second = batch.send(:register_unit, 'at the altar')
    unit = described_class::Unit.new(
      key: 'movable-nested-editorial-citation',
      prepared: '__P0001__ before __P0002__ <span data-ewprs="22">editorial note</span>',
      tokens: {
        '__P0001__' => "[[#{first}]]", '__P0002__' => "[[#{second}]]"
      }
    )
    translated = '__P0002__ 在 __P0001__ 之前<span data-ewprs="22">编辑说明</span>'

    expect(batch.send(:valid_editorial_structure?, unit, translated)).to be(true)
  end

  it 'rejects editorial boundaries moved across protected nested editorial values' do
    nested = batch.send(:register_unit, 'unit cognition')
    unit = described_class::Unit.new(
      key: 'nested-editorial-scope',
      prepared: 'plate <span data-ewprs="11">within the unit</span> is __P0001__',
      tokens: {'__P0001__' => "a&#x301;tma&#x301; [#{nested}]"}
    )
    translated = 'plate <span data-ewprs="11">within the unit is __P0001__</span>'

    expect(batch.send(:valid_editorial_structure?, unit, translated)).to be(false)
  end

  it 'rejects cached translations with nested editorial bracket scope changes' do
    nested = batch.send(:register_unit, 'unit cognition')
    unit = described_class::Unit.new(
      key: 'cached-nested-editorial-scope',
      source: 'plate [within the unit] is a&#x301;tma&#x301; [unit cognition].',
      prepared: 'plate <span data-ewprs="11">within the unit</span> is __P0001__.',
      tokens: {'__P0001__' => "a&#x301;tma&#x301; [#{nested}]"}
    )

    expect do
      batch.send(
        :validate_restored_translation!, unit,
        "板块[在单元内是a&#x301;tma&#x301; [#{nested}]。]"
      )
    end.to raise_error(Ewprs::TranslationValidator::Error, /changed editorial brackets/)
  end

  it 'allows a nested parenthetical to move around an editorial citation' do
    nested = batch.send(:register_unit, 'not more than two tolas')
    unit = described_class::Unit.new(
      key: 'movable-parenthetical-citation',
      prepared: 'aged tamarind <span data-ewprs="11">__P0001__Tamarindus indica Linn.__P0002__</span> ' \
                'in very small quantity __P0003__ with the meal',
      tokens: {
        '__P0001__' => '<i>', '__P0002__' => '</i>', '__P0003__' => "(#{nested})"
      },
      leading: '', trailing: ''
    )
    translated = 'in sehr geringer Menge __P0003__ gereifter Tamarinde ' \
                 '<span data-ewprs="11">__P0001__Tamarindus indica Linn.__P0002__</span> zur Mahlzeit'

    expect(batch.send(:valid_editorial_structure?, unit, translated)).to be(true)
    restored = batch.send(:restore_editorial_tags, translated)
      .gsub(described_class::PLACEHOLDER) { |marker| unit.tokens.fetch(marker) }
    expect(batch.send(:validate_restored_translation!, unit, restored)).to eq(restored)
  end

  it 'rejects restored translations that retain source prose before caching' do
    unit = described_class::Unit.new(
      key: 'restored-source-prose',
      source: 'The human mind can move through the world in many different ways.',
      prepared: 'The human mind can move through the world in many different ways.',
      tokens: {}, leading: '', trailing: ''
    )

    expect { batch.send(:restore_tokens, unit, unit.prepared) }
      .to raise_error(Ewprs::TranslationValidator::Error, /source prose unchanged/)
  end

  it 'removes natural dashes duplicated beside preserved character references' do
    unit = described_class::Unit.new(
      key: 'duplicated-dash', source: 'One &ndash; two.', prepared: 'One &ndash; two.',
      tokens: {}, leading: '', trailing: ''
    )

    expect(batch.send(:validate_restored_translation!, unit, 'Um &ndash; – dois.')).to eq(
      'Um &ndash; dois.'
    )
  end

  it 'validates nested child prose independently from its parent unit' do
    child = 'Second English publication in Subhasita Samgraha Part 11.'
    child_marker = batch.send(:register_unit, child)
    unit = described_class::Unit.new(
      key: 'nested-validation', source: "[[#{child}]] English re-editing by ACAA.",
      prepared: '__P0001__ English re-editing by __P0002__.',
      tokens: {'__P0001__' => "[[#{child_marker}]]", '__P0002__' => 'ACAA'},
      leading: '', trailing: ''
    )

    expect(
      batch.send(:validate_restored_translation!, unit, "[[#{child_marker}]] Revisão em inglês por ACAA.")
    ).to eq("[[#{child_marker}]] Revisão em inglês por ACAA.")
  end

  it 'excludes a protected title around nested child prose from outer progress validation' do
    unit = batch.send(
      :prepare_unit, 'nested-protected-title',
      'The subject of today&#146;s discourse is &ldquo;Human Life and Its [[Goal]]&rdquo;.'
    )
    title = unit.tokens.fetch('__P0001__')

    expect(
      batch.send(
        :validate_restored_translation!, unit,
        "Das Thema der heutigen Diskussion ist #{title}."
      )
    ).to eq("Das Thema der heutigen Diskussion ist #{title}.")
    expect do
      batch.send(
        :validate_restored_translation!, unit,
        "The subject of today's discourse is #{title}."
      )
    end.to raise_error(Ewprs::TranslationValidator::Error, /source prose unchanged/)
  end

  it 'projects nested units from the prepared layout when editorial scope was normalized' do
    child_marker = batch.send(:register_unit, 'nerve-cells come into play')
    unit = described_class::Unit.new(
      key: 'normalized-editorial-source', source: 'nerve[-cells] come into play',
      prepared: '__P0001__', tokens: {'__P0001__' => "[#{child_marker}]"},
      leading: '', trailing: ''
    )

    expect(
      batch.send(:validate_restored_translation!, unit, "[#{child_marker}]")
    ).to eq("[#{child_marker}]")
  end

  it 'projects nested gloss delimiters from protected values during editorial validation' do
    child_marker = batch.send(:register_unit, 'Orissa')
    unit = described_class::Unit.new(
      key: 'protected-nested-editorial',
      source: 'Kaliun&#x32D;ga [Orissa], Mithila and Magadha [Bihar] as parts of their A&#x301;ryavartta.',
      prepared: '__P0001__, Mithila and Magadha <span data-ewprs="11">Bihar</span> as parts of their __P0002__.',
      tokens: {
        '__P0001__' => "Kaliun&#x32D;ga [#{child_marker}]", '__P0002__' => 'A&#x301;ryavartta'
      },
      leading: '', trailing: ''
    )
    translated = '__P0001__, Mithila e Magadha <span data-ewprs="11">Bihar</span> ' \
                 'como partes de seu __P0002__.'

    expect(batch.send(:restore_tokens, unit, translated)).to eq(
      "Kaliun&#x32D;ga [#{child_marker}], Mithila e Magadha [Bihar] como partes de seu A&#x301;ryavartta."
    )
  end

  it 'masks orphan double editorial brackets as one structural token' do
    unit = batch.send(
      :prepare_unit, 'orphan-closing-brackets',
      'From it the word natural comes; and also]] native.'
    )

    expect(unit.prepared).to eq('From it the word natural comes; and also__P0001__ native.')
    expect(unit.tokens).to eq('__P0001__' => ']]')
  end

  def prepare_translation(instance)
    entry = described_class::Entry.new(kind: :discourse, path: File.join(root, 'HTML/Discourses/Complete.html'))
    documents = instance.send(:prepare_documents, [entry])
    [documents.first, instance.send(:translate_units)]
  end
end
