require 'spec_helper'
require_relative '../../lib/ewprs'

RSpec.describe Ewprs::TranslationBatch do
  class FakeMarkupTranslator
    attr_reader :calls, :repair_calls

    def initialize(&transform)
      @transform = transform || ->(text) { text.gsub('English', 'Português').gsub('Translate me', 'Traduza-me') }
      @calls = []
      @repair_calls = []
    end

    def translate_markup(texts, to:)
      @calls.concat(texts)
      texts.map(&@transform)
    end

    def repair_markup(source, tokens:, to:)
      @repair_calls << {source: source, tokens: tokens, to: to}
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
    expect(result[:protected_elements]).to eq(5)
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
    expect(translator.calls).to include('&ldquo;English rendering!', 'English second rendering!&rdquo;')
    expect(translator.calls).to include('English introduction, __P0001__', 'English after.')
    expect(rendered).to include(
      'Português introduction, Eso A&#x301;y bet&#x301;a&#x301; toke dekhe noba. ' \
      '[&ldquo;Português rendering! Português second rendering!&rdquo;] Português after.'
    )
  end

  it 'translates a marked Sanskrit gloss as a nested unit' do
    document, translations = prepare_translation(batch)
    rendered = batch.send(:render, document, translations)

    expect(translator.calls).to include('English bliss', 'English middle')
    expect(rendered).to include(
      'Português about <i>A&#x301;nanda karma</i> [Português bliss] and madhyama [Português middle].'
    )
  end

  it 'makes one protected occurrence explicit across quantified coordination' do
    unit = batch.send(
      :prepare_unit, 'coordination',
      'Vital energy passes through five internal and five external Vayus (airs).'
    )

    expect(unit.prepared).to eq(
      'Vital energy passes through five internal __P0001__ and five external ones (airs).'
    )
    expect(unit.tokens).to eq('__P0001__' => 'Vayus')
  end

  it 'rejects translations that alter editorial brackets' do
    document, translations = prepare_translation(batch)
    rendered = batch.send(:render, document, translations).sub('[&ldquo;', '&ldquo;')

    expect { batch.send(:validate_structure!, source, rendered) }.to raise_error(/editorial brackets changed/)
  end

  it 'keeps complete footnotes out of model input' do
    document, translations = prepare_translation(batch)
    rendered = batch.send(:render, document, translations)

    expect(translator.calls.join).not_to include('Ref.fn2')
    expect(rendered).to include(
      '<!-- fn --><a name="Ref.fn2"></a><sup>(<b><a href="#fn2">2</a></b>)</sup><!-- /fn -->'
    )
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

  it 'rejects translations that alter protected tokens' do
    broken = FakeMarkupTranslator.new { |text| text.sub(/__P\d{4}__/, '') }
    invalid = described_class.new(root: root, cache: cache, translator: broken, stdout: StringIO.new)
    entry = described_class::Entry.new(kind: :discourse, path: File.join(root, 'HTML/Discourses/Complete.html'))
    invalid.send(:prepare_documents, [entry])

    expect { invalid.send(:translate_units) }.to raise_error(/changed protected tokens/)
  end

  it 'retries transient protected-token corruption serially' do
    corrupted = false
    flaky = FakeMarkupTranslator.new do |text|
      if !corrupted && text.match?(/__P\d{4}__/)
        corrupted = true
        text.sub(/__P\d{4}__/, '')
      else
        text
      end
    end
    retried = described_class.new(root: root, cache: cache, translator: flaky, stdout: StringIO.new)

    expect { prepare_translation(retried) }.not_to raise_error
    expect(corrupted).to be(true)
    expect(flaky.repair_calls).not_to be_empty
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

  it 'rejects reordered structural tokens' do
    unit = described_class::Unit.new(
      key: 'markup', prepared: '__P0001__English__P0002__',
      tokens: {'__P0001__' => '<i>', '__P0002__' => '</i>'},
      leading: '', trailing: ''
    )

    expect { batch.send(:restore_tokens, unit, '__P0002__Português__P0001__') }
      .to raise_error(/reordered structural tokens/)
  end

  def prepare_translation(instance)
    entry = described_class::Entry.new(kind: :discourse, path: File.join(root, 'HTML/Discourses/Complete.html'))
    documents = instance.send(:prepare_documents, [entry])
    [documents.first, instance.send(:translate_units)]
  end
end
