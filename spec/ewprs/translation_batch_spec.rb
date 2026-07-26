require 'spec_helper'
require_relative '../../lib/ewprs'

RSpec.describe Ewprs::TranslationBatch do
  class FakeMarkupTranslator
    attr_reader :calls, :repair_calls

    def initialize(&transform)
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
      '<p><b>Vayus</b> vital airs</p></body></html>'
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

  it 'uses the EWPRS sentence splitter for independent translation units' do
    prepare_translation(batch)

    expect(translator.calls).to include('English plain sentence.')
    expect(translator.calls).to include(a_string_matching(/\A__P\d{4}__English next sentence\.__P\d{4}__\z/))
    expect(translator.calls).not_to include(a_string_including('English plain sentence. <b>'))
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

  it 'sentence-splits content enclosed by one outer editorial bracket pair' do
    template = batch.send(:register_content, '[First English sentence. Second English sentence.]')

    expect(template).to match(/\A\[⟦U[0-9a-f]{64}⟧ ⟦U[0-9a-f]{64}⟧\]\z/)
    expect(batch.instance_variable_get(:@units).values.map(&:source)).to include(
      'First English sentence.', 'Second English sentence.'
    )
    expect(batch.instance_variable_get(:@units).values.map(&:prepared).join).not_to include('data-ewprs')
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

    expect(parted.tokens.values).to include('Ananda Marga Ideology and Way of Life in a Nutshell')
    expect(volume.tokens.values).to include(
      '&ldquo;How to Unite Human Society&rdquo;', 'Prout in a Nutshell'
    )
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

    expect(year.tokens.values).to include('A Guide to Human Conduct')
    expect(edition.tokens.values).to include('A Guide to Human Conduct')
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

  it 'uses one repeated placeholder for identical protected values' do
    unit = batch.send(:prepare_unit, 'repeated-value', 'Dharma supports Dharma.')

    expect(unit.prepared).to eq('__P0001__ supports __P0001__.')
    expect(unit.tokens).to eq('__P0001__' => 'Dharma')
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

  it 'translates repeated identical editorial inserts as one nested unit token' do
    unit = batch.send(
      :prepare_unit, 'repeated-editorial',
      'Prakrti is the secondary [efficient cause], Purusa is the chief [efficient cause].'
    )

    repeated = unit.prepared.scan(described_class::PLACEHOLDER).tally.find { |_marker, count| count == 2 }
    expect(repeated).not_to be_nil
    expect(unit.tokens.fetch(repeated.first)).to match(/\A\[⟦U[0-9a-f]{64}⟧\]\z/)
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

  it 'protects a foreign inline phrase as one immutable token' do
    unit = batch.send(:prepare_unit, 'foreign-inline', 'The phrase <i>praka&#x301;ram&#x301; karoti iti</i> is used.')

    expect(unit.prepared).to eq('The phrase __P0001__ is used.')
    expect(unit.tokens).to eq('__P0001__' => '<i>praka&#x301;ram&#x301; karoti iti</i>')
  end

  it 'rejects translations that alter protected tokens' do
    broken = FakeMarkupTranslator.new do |text|
      text.gsub('English', 'Português').gsub('Translate me', 'Traduza-me').gsub(/\band\b/, 'e')
        .sub(/__P\d{4}__/, '')
    end
    invalid = described_class.new(root: root, cache: cache, translator: broken, stdout: StringIO.new)
    entry = described_class::Entry.new(kind: :discourse, path: File.join(root, 'HTML/Discourses/Complete.html'))
    invalid.send(:prepare_documents, [entry])

    expect { invalid.send(:translate_units) }.to raise_error(/changed protected tokens.*missing:/)
  end

  it 'retries transient protected-token corruption serially' do
    corrupted = false
    flaky = FakeMarkupTranslator.new do |text|
      if !corrupted && text.match?(/__P\d{4}__/)
        corrupted = true
        text.sub(/__P\d{4}__/, '')
      else
        text.gsub('English', 'Português').gsub('Translate me', 'Traduza-me').gsub(/\band\b/, 'e')
      end
    end
    retried = described_class.new(root: root, cache: cache, translator: flaky, stdout: StringIO.new)

    expect { prepare_translation(retried) }.not_to raise_error
    expect(corrupted).to be(true)
    expect(flaky.repair_calls).not_to be_empty
  end

  it 'includes nested source text in repair token meanings' do
    nested_marker = batch.send(:register_unit, 'the headquarters of Ananda Marga')
    tokens = {'__P0001__' => "(#{nested_marker})"}

    expect(batch.send(:repair_token_values, tokens)).to eq(
      '__P0001__' => '(the headquarters of Ananda Marga)'
    )
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
