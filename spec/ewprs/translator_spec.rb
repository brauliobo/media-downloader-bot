require 'spec_helper'
require_relative '../../lib/ewprs/translator'

RSpec.describe Ewprs::Translator do
  subject(:translator) { described_class.new }

  around do |example|
    keys = %w[HYMT2_HOST HYMT2_MODEL HYMT2_CONCURRENCY EWPRS_TRANSLATION_MAX_TOKENS]
    original = ENV.values_at(*keys)
    ENV['HYMT2_HOST']                    = 'http://127.0.0.1:12002/'
    ENV['HYMT2_MODEL']                   = 'Hy-MT2-7B-Q4_K_M.gguf'
    ENV['HYMT2_CONCURRENCY']             = '1'
    ENV['EWPRS_TRANSLATION_MAX_TOKENS']  = '2048'
    example.run
  ensure
    keys.zip(original).each do |key, value|
      value ? ENV[key] = value : ENV.delete(key)
    end
  end

  it 'translates protected markup through the isolated HyMT2 client' do
    expect(Utils::HTTP).to receive(:post) do |url, body, headers|
      payload = JSON.parse(body)
      expect(url).to eq('http://127.0.0.1:12002/v1/chat/completions')
      expect(headers).to eq('Content-Type' => 'application/json')
      expect(payload['model']).to eq('Hy-MT2-7B-Q4_K_M.gguf')
      expect(payload['temperature']).to eq(0)
      expect(payload['max_tokens']).to eq(2048)
      prompt = payload.dig('messages', 0, 'content')
      expect(prompt).to include(
        'Brazilian Portuguese',
        'Preserve every sentence and line break',
        'Choose one direct translation; do not output alternatives, annotations, or parenthetical variants.',
        'Translate prose inside quotation marks too; quotation marks do not denote protected text.',
        'including unmatched delimiters: "("=0, ")"=0, "["=0, "]"=0, "{"=0, "}"=0',
        'Preserve exactly these placeholder occurrences, including every repeated entry, without translating or ' \
        'renumbering them: ZXQEWPRSP1ZXQ. Do not append this list to the translation.',
        'ZXQEWPRSP1ZXQ'
      )
      expect(prompt).not_to include('Interpret the English verb "means"')
      Struct.new(:body).new(
        {choices: [{message: {content: "  A palavra ZXQEWPRSP1ZXQ significa felicidade.\n"}}]}.to_json
      )
    end

    expect(translator.translate_markup('The word __P0001__ means bliss.', to: 'pt')).to eq(
      'A palavra __P0001__ significa felicidade.'
    )
  end

  it 'provides source-language meaning for rare English terms' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include('Interpret the English adjective "trifarious" as "threefold".')
      Struct.new(:body).new(
        {choices: [{message: {content: 'Dreifache Ausdrucksweise'}}]}.to_json
      )
    end

    expect(translator.translate_markup('Trifarious Expression', to: 'de')).to eq('Dreifache Ausdrucksweise')
  end

  it 'provides semantic paraphrases for model code-switch triggers' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        'Interpret the phrase "all of North Bengal" to mean every part of the geographic region North Bengal.',
        'Interpret the English adjective "illustrative" as "serving as examples".',
        'Interpret the English word "definition" as "statement of meaning".',
        'Interpret the English noun "feeder" as "one who nourishes or supplies".',
        'Interpret the English adjective "descended" as "derived from an earlier language".',
        'Interpret the English adjective "illiterate" as "unable to read or write".',
        'Interpret the English noun "linseed" as "flax seed".',
        'Interpret the English adverb "respectively" as "in the same order".',
        'This phrase introduces a list of examples. Translate every word of the phrase.'
      )
      Struct.new(:body).new(
        {choices: [{message: {content: 'In der gesamten Region Nordbengalen gibt es anschauliche Beispiele.'}}]}.to_json
      )
    end

    source = 'All of North Bengal has illustrative examples by definition for each feeder. Some examples are ' \
             'illiterate, respectively descended, and contain linseed.'
    expect(translator.translate_markup(source, to: 'de')).to eq(
      'In der gesamten Region Nordbengalen gibt es anschauliche Beispiele.'
    )
  end

  it 'uses explicit jobs as distributed request concurrency' do
    expect(described_class.new(jobs: '40').jobs).to eq(40)
  end

  it 'limits concurrent requests across overlapping translation calls' do
    translator = described_class.new(jobs: 2)
    active = 0
    maximum = 0
    mutex = Mutex.new
    allow(Utils::HTTP).to receive(:post) do
      mutex.synchronize do
        active += 1
        maximum = [maximum, active].max
      end
      sleep 0.05
      Struct.new(:body).new({choices: [{message: {content: 'Übersetzt'}}]}.to_json)
    ensure
      mutex.synchronize { active -= 1 }
    end

    2.times.map do
      Thread.new { translator.translate_markup(%w[First Second], to: 'de') }
    end.each(&:value)

    expect(maximum).to eq(2)
  end

  it 'retries brief transport interruptions' do
    calls = 0
    allow(Utils::HTTP).to receive(:post) do
      calls += 1
      raise EOFError if calls <= 3

      Struct.new(:body).new({choices: [{message: {content: 'Übersetzt'}}]}.to_json)
    end
    expect(translator).to receive(:sleep).with(2).exactly(3).times

    expect(translator.translate_markup('Translated', to: 'de')).to eq('Übersetzt')
    expect(calls).to eq(4)
  end

  it 'retries model request timeouts' do
    calls = 0
    allow(Utils::HTTP).to receive(:post) do
      calls += 1
      raise Net::ReadTimeout if calls == 1

      Struct.new(:body).new({choices: [{message: {content: 'Übersetzt'}}]}.to_json)
    end
    expect(translator).to receive(:sleep).with(2).once

    expect(translator.translate_markup('Translated', to: 'de')).to eq('Übersetzt')
    expect(calls).to eq(2)
  end

  it 'retries transient model server responses' do
    calls = 0
    server_error = Mechanize::ResponseCodeError.new(Struct.new(:code).new('500'))
    allow(Utils::HTTP).to receive(:post) do
      calls += 1
      raise server_error if calls <= 2

      Struct.new(:body).new({choices: [{message: {content: 'Übersetzt'}}]}.to_json)
    end
    expect(translator).to receive(:sleep).with(2).twice

    expect(translator.translate_markup('Translated', to: 'de')).to eq('Übersetzt')
    expect(calls).to eq(3)
  end

  it 'translates unmatched smart-quote prose separately after repeated model format failures' do
    calls = 0
    server_error = Mechanize::ResponseCodeError.new(Struct.new(:code).new('500'))
    allow(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      calls += 1
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      raise server_error if prompt.include?('<ewprs-quote-open')

      Struct.new(:body).new({choices: [{message: {content: '我的主啊。'}}]}.to_json)
    end
    expect(translator).to receive(:sleep).with(2).exactly(3).times

    expect(translator.translate_markup('&ldquo;Oh my Lord.', to: 'zh')).to eq('&ldquo;我的主啊。')
    expect(calls).to eq(5)
  end

  it 'limits transport retries' do
    expect(Utils::HTTP).to receive(:post).exactly(4).times.and_raise(Errno::ECONNRESET)
    expect(translator).to receive(:sleep).with(2).exactly(3).times

    expect { translator.translate_markup('Translated', to: 'de') }.to raise_error(Errno::ECONNRESET)
  end

  it 'removes an exact echoed source line before the translation' do
    expect(Utils::HTTP).to receive(:post).and_return(
      Struct.new(:body).new(
        {
          choices: [
            {message: {content: "By nature the human mind is liberated.  \n" \
                                'Der menschliche Verstand ist von Natur aus befreit.'}}
          ]
        }.to_json
      )
    )

    expect(translator.translate_markup('By nature the human mind is liberated.', to: 'de')).to eq(
      'Der menschliche Verstand ist von Natur aus befreit.'
    )
  end

  it 'enumerates every placeholder occurrence' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        'Preserve exactly these placeholder occurrences, including every repeated entry, without translating or ' \
        'renumbering them: ZXQEWPRSP2ZXQ, ZXQEWPRSP1ZXQ, ZXQEWPRSP2ZXQ. ' \
        'Do not append this list to the translation.'
      )
      Struct.new(:body).new(
        {choices: [{message: {content: 'ZXQEWPRSP2ZXQ Buda ZXQEWPRSP1ZXQ ZXQEWPRSP2ZXQ'}}]}.to_json
      )
    end

    expect(translator.translate_markup('__P0002__ Buddha __P0001__ __P0002__', to: 'pt')).to eq(
      '__P0002__ Buda __P0001__ __P0002__'
    )
  end

  it 'restores a wire placeholder whose suffix was truncated' do
    expect(Utils::HTTP).to receive(:post).and_return(
      Struct.new(:body).new(
        {choices: [{message: {content: '芒果ZXQEWPRSP17品种'}}]}.to_json
      )
    )

    expect(translator.translate_markup('Mango __P0017__ variety', to: 'zh')).to eq(
      '芒果__P0017__品种'
    )
  end

  it 'protects HTML character references from the translation model' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        '<ewprs-quote-open id="1"/>The word<ewprs-quote-close id="2"/> ' \
        'ZXQEWPRSE3ZXQ another word ZXQEWPRSE4ZXQ:',
        'ZXQEWPRSE3ZXQ, ZXQEWPRSE4ZXQ',
        '<ewprs-quote-open id="1"/>, <ewprs-quote-close id="2"/>'
      )
      expect(prompt).not_to include('&ldquo;', '&rdquo;', '&ndash;', '&nbsp')
      Struct.new(:body).new(
        {
          choices: [
            {
              message: {
                content: '<ewprs-quote-open id="1"/>A palavra<ewprs-quote-close id="2"/> ' \
                         'ZXQEWPRSE3ZXQ outra palavra ZXQEWPRSE4ZXQ:'
              }
            }
          ]
        }.to_json
      )
    end

    expect(
      translator.translate_markup('&ldquo;The word&rdquo; &ndash; another word &nbsp:', to: 'pt')
    ).to eq('&ldquo;A palavra&rdquo; &ndash; outra palavra &nbsp:')
  end

  it 'assigns a distinct placeholder to every repeated character reference' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        '<ewprs-quote-open id="1"/>One<ewprs-quote-close id="2"/> and ' \
        '<ewprs-quote-open id="3"/>two<ewprs-quote-close id="4"/>',
        '<ewprs-quote-open id="1"/>, <ewprs-quote-close id="2"/>, ' \
        '<ewprs-quote-open id="3"/>, <ewprs-quote-close id="4"/>'
      )
      Struct.new(:body).new(
        {
          choices: [
            {
              message: {
                content: '<ewprs-quote-open id="1"/>Um<ewprs-quote-close id="2"/> e ' \
                         '<ewprs-quote-open id="3"/>dois<ewprs-quote-close id="4"/>'
              }
            }
          ]
        }.to_json
      )
    end

    expect(
      translator.translate_markup('&ldquo;One&rdquo; and &ldquo;two&rdquo;', to: 'pt')
    ).to eq('&ldquo;Um&rdquo; e &ldquo;dois&rdquo;')
  end

  it 'translates prose segments while preserving smart quote delimiters and editorial tags' do
    expect(translator).to receive(:translate_markup).with(
      ['The statement', 'The', 'selection board', 'stopped.'], from: 'en', to: 'pt'
    ).and_return(['«A afirmação»', 'O', 'comitê de seleção', 'parou.'])

    expect(
      translator.translate_preserving_smart_quotes(
        '<span data-ewprs="11">The statement</span> &ldquo;The &lsquo;selection board&rsquo; stopped.&rdquo;',
        to: 'pt'
      )
    ).to eq(
      '<span data-ewprs="11">A afirmação</span> &ldquo;O &lsquo;comitê de seleção&rsquo; parou.&rdquo;'
    )
  end

  it 'uses mandatory XML tags as an alternate protected-placeholder channel' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        'Preserve this exact HTML tag sequence without adding, omitting, changing, or reordering tags: ' \
        '<ewprs-p id="1"/>.',
        'The natural <ewprs-p id="1"/> remains.'
      )
      Struct.new(:body).new(
        {choices: [{message: {content: 'Das natürliche <ewprs-p id="1"/> bleibt bestehen.'}}]}.to_json
      )
    end

    expect(
      translator.translate_preserving_placeholders('The natural __P0001__ remains.', to: 'de')
    ).to eq('Das natürliche __P0001__ bleibt bestehen.')
  end

  it 'exposes protected values inside semantic XML tags' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include('<ewprs-p id="1">Prakrti</ewprs-p> is named.')
      Struct.new(:body).new(
        {choices: [{message: {content: '<ewprs-p id="1">Prakrti</ewprs-p> wird benannt.'}}]}.to_json
      )
    end

    expect(
      translator.translate_preserving_placeholders(
        '__P0001__ is named.', values: {'__P0001__' => 'Prakrti'}, to: 'de'
      )
    ).to eq('__P0001__ wird benannt.')
  end

  it 'retranslates clauses when a full XML translation drops placeholders' do
    allow(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      content = if prompt.include?('The <ewprs-p id="1"/> improves, while <ewprs-p id="2"/> grows.')
                  'Der <ewprs-p id="1"/> verbessert sich.'
                elsif prompt.include?('The <ewprs-p id="1"/> improves')
                  'Der <ewprs-p id="1"/> verbessert sich'
                elsif prompt.include?('while <ewprs-p id="2"/> grows.')
                  'während <ewprs-p id="2"/> wächst.'
                end
      Struct.new(:body).new({choices: [{message: {content: content}}]}.to_json)
    end

    expect(
      translator.translate_preserving_placeholders(
        'The __P0001__ improves, while __P0002__ grows.', to: 'de'
      )
    ).to eq('Der __P0001__ verbessert sich, während __P0002__ wächst.')
  end

  it 'translates between placeholders when XML clause retries still drop one' do
    allow(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      content = if prompt.include?('<ewprs-p')
                  if prompt.include?('Before <ewprs-p id="1"/>, between <ewprs-p id="2"/>, after.')
                    '之前<ewprs-p id="1"/>,之后。'
                  elsif prompt.include?('Before <ewprs-p id="1"/>')
                    '之前<ewprs-p id="1"/>'
                  elsif prompt.include?('between <ewprs-p id="2"/>')
                    '之间'
                  else
                    '之后。'
                  end
                elsif prompt.match?(/\n\nBefore\z/)
                  '之前'
                elsif prompt.match?(/\n\n, between\z/)
                  '，之间'
                elsif prompt.match?(/\n\nafter\.\z/)
                  '之后。'
                elsif prompt.match?(/\n\n, after\.\z/)
                  '，之后。'
                end
      Struct.new(:body).new({choices: [{message: {content: content}}]}.to_json)
    end

    expect(
      translator.translate_preserving_placeholders(
        'Before __P0001__, between __P0002__, after.', to: 'zh'
      )
    ).to eq('之前 __P0001__，之间 __P0002__，之后。')
  end

  it 'preserves placeholder order while translating intervening prose' do
    allow(translator).to receive(:translate_markup).with(
      ['Before', 'between', 'after.'], from: 'en', to: 'zh'
    ).and_return(['之前', '之间', '之后。'])

    expect(
      translator.translate_preserving_placeholder_order(
        'Before __P0001__ between __P0002__ after.', to: 'zh'
      )
    ).to eq('之前 __P0001__ 之间 __P0002__ 之后。')
  end

  it 'retries an echoed XML translation with natural protected values and punctuation' do
    source = '__P0001__ &ndash; in this __P0002__ the body even the knowledge of ' \
             '&ldquo;I&rdquo; is not much in evidence.'
    allow(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      content = if prompt.include?('<ewprs-p id="1">Hirańmaya Kośa</ewprs-p>')
                  '<ewprs-p id="1">Hirańmaya Kośa</ewprs-p> ZXQEWPRSE1ZXQ in this ' \
                    '<ewprs-p id="2">kośa</ewprs-p> the body even the knowledge of ' \
                    '<ewprs-quote-open id="2"/>I<ewprs-quote-close id="3"/> is not much in evidence.'
                else
                  expect(prompt).to include(
                    'Hiranmaya Kosa – in this kosa the body even the knowledge of “I” is not much in evidence.'
                  )
                  'Hiranmaya Kosa – in dieser Kosa ist der Körper sowie das Wissen vom „Ich“ kaum erkennbar.'
                end
      Struct.new(:body).new({choices: [{message: {content: content}}]}.to_json)
    end

    expect(
      translator.translate_preserving_placeholders(
        source,
        values: {'__P0001__' => 'Hiran&#x301;maya Kos&#x301;a', '__P0002__' => 'kos&#x301;a'},
        to: 'de'
      )
    ).to eq(
      '__P0001__ &ndash; in dieser __P0002__ ist der Körper sowie das Wissen vom ' \
      '&ldquo;Ich&rdquo; kaum erkennbar.'
    )
  end

  it 'translates prose between placeholders when semantic and natural translations are echoed' do
    source = '__P0001__ in __P0002__ Bengali, rather than __P0003__'
    allow(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      content = if prompt.include?('<ewprs-p id="1">mohará</ewprs-p>')
                  '<ewprs-p id="1">mohará</ewprs-p> in <ewprs-p id="2">Ráŕhii</ewprs-p> Bengali, ' \
                    'rather than <ewprs-p id="3">mukhośa</ewprs-p>'
                elsif prompt.include?('mohara in Rarhii Bengali, rather than mukhosa')
                  'mohara in Rarhii Bengali, rather than mukhosa'
                elsif prompt.match?(/\n\nin\z/)
                  'in'
                elsif prompt.include?("\n\nBengali, rather than")
                  'Bengalisch, anstatt'
                end
      Struct.new(:body).new({choices: [{message: {content: content}}]}.to_json)
    end

    expect(
      translator.translate_preserving_placeholders(
        source,
        values: {
          '__P0001__' => 'mohara&#x301;',
          '__P0002__' => 'Ra&#x301;r&#x301;hii',
          '__P0003__' => 'mukhos&#x301;a'
        },
        to: 'de'
      )
    ).to eq('__P0001__ in __P0002__ Bengalisch, anstatt __P0003__')
  end

  it 'translates entity-heavy prose with natural punctuation and restores its references' do
    source = 'I offer flowers &ndash; all were created by you.'
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include('I offer flowers – all were created by you.')
      expect(prompt).not_to include('ZXQEWPRSE')
      Struct.new(:body).new(
        {choices: [{message: {content: 'Ich biete Blumen an – alle wurden von dir erschaffen.'}}]}.to_json
      )
    end

    expect(translator.translate_preserving_character_references(source, to: 'de')).to eq(
      'Ich biete Blumen an &ndash; alle wurden von dir erschaffen.'
    )
  end

  it 'retranslates echoed comma-separated prose as smaller fragments' do
    source = 'So in that first figure, in that first geometrical figure, at the dawn of creation, ' \
             'there may be more than one line,'
    expect(translator).to receive(:translate_markup).with(
      [
        'So in that first figure', 'in that first geometrical figure',
        'at the dawn of creation', 'there may be more than one line'
      ], from: 'en', to: 'de'
    ).and_return(
      [
        'So in that first figure', 'in dieser ersten geometrischen Figur',
        'zu Beginn der Schöpfung', 'Es kann mehr als eine Zeile geben.'
      ]
    )
    expect(translator).to receive(:translate_markup).with(
      ['So', 'in that first figure'], from: 'en', to: 'de'
    ).and_return(['So', 'in jener ersten Figur'])

    expect(translator.translate_by_clauses(source, to: 'de')).to eq(
      'So in jener ersten Figur, in dieser ersten geometrischen Figur, zu Beginn der Schöpfung, ' \
      'es kann mehr als eine Zeile geben,'
    )
  end

  it 'does not seed placeholders into unprotected translation prompts' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include('They say that in this case the')
      expect(prompt).not_to include('__P0001__')
      Struct.new(:body).new({choices: [{message: {content: 'Dizem que, neste caso, o'}}]}.to_json)
    end

    expect(translator.translate_markup('They say that in this case the', to: 'pt')).to eq(
      'Dizem que, neste caso, o'
    )
  end

  it 'requires the exact HTML tag sequence in translated output' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        'Preserve this exact HTML tag sequence without adding, omitting, changing, or reordering tags: ' \
        '<span data-ewprs="22">, </span>.'
      )
      Struct.new(:body).new(
        {choices: [{message: {content: '<span data-ewprs="22">forma</span>'}}]}.to_json
      )
    end

    expect(
      translator.translate_markup('<span data-ewprs="22">form</span>', to: 'pt')
    ).to eq('<span data-ewprs="22">forma</span>')
  end

  it 'retranslates with semantic context without changing placeholder multiplicity' do
    source = 'where __P0002__ is present dominant __P0003__ is ordinary and __P0004__ is negligible.'
    invalid = 'onde __P0002__ está presente, é dominante e __P0004__ é insignificante.'
    issue = 'translation changed protected tokens'
    corrected = 'onde __P0002__ é dominante, __P0003__ é comum e __P0004__ é insignificante.'
    tokens = {
      '__P0002__' => 'Tamogun&#x301;a',
      '__P0003__' => 'Rajogun&#x301;a',
      '__P0004__' => 'sattvagun&#x301;a'
    }
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        source.gsub('__P0002__', 'ZXQEWPRSP2ZXQ').gsub('__P0003__', 'ZXQEWPRSP3ZXQ')
          .gsub('__P0004__', 'ZXQEWPRSP4ZXQ'),
        invalid.gsub('__P0002__', 'ZXQEWPRSP2ZXQ').gsub('__P0003__', 'ZXQEWPRSP3ZXQ')
          .gsub('__P0004__', 'ZXQEWPRSP4ZXQ'), issue,
        'Translate every English prose word outside placeholders; do not copy source-language prose.',
        'Copy every placeholder literally; never replace it with its meaning.',
        'ZXQEWPRSP2ZXQ = Tamoguna', 'ZXQEWPRSP3ZXQ = Rajoguna', 'ZXQEWPRSP4ZXQ = sattvaguna'
      )
      encoded = corrected.gsub('__P0002__', 'ZXQEWPRSP2ZXQ').gsub('__P0003__', 'ZXQEWPRSP3ZXQ')
        .gsub('__P0004__', 'ZXQEWPRSP4ZXQ')
      Struct.new(:body).new({choices: [{message: {content: encoded}}]}.to_json)
    end

    expect(
      translator.repair_markup(source, invalid: invalid, issue: issue, tokens: tokens, to: 'pt')
    ).to eq(corrected)
  end

  it 'uses a concise full-retranslation prompt for retained source prose' do
    source = 'Spraying water like a fountain is also called __P0001__.'
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        'Translate this English sentence completely into Brazilian Portuguese.',
        'Do not output any English words.',
        'Preserve every sentence and line break',
        'including unmatched delimiters',
        'Preserve exactly these placeholder occurrences, including every repeated entry',
        source.gsub('__P0001__', 'ZXQEWPRSP1ZXQ')
      )
      expect(prompt).not_to include('Invalid translation to correct:')
      Struct.new(:body).new(
        {choices: [{message: {content: 'Borrifar água como uma fonte também se chama ZXQEWPRSP1ZXQ.'}}]}.to_json
      )
    end

    expect(
      translator.repair_markup(
        source, invalid: source, issue: 'translation retained a long source-language span',
        tokens: {'__P0001__' => 'karapatrika'}, to: 'pt'
      )
    ).to eq('Borrifar água como uma fonte também se chama __P0001__.')
  end

  it 'retranslates foreign-script failures from source without repeating the invalid output' do
    source = 'It is to inject the spirit of movement from the lowermost point.'
    invalid = 'Es soll den Geist der Bewegung 注入.'
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        'Translate this English sentence completely into German.',
        'Interpret the English verb "inject" as "introduce or instill".',
        source
      )
      expect(prompt).not_to include(invalid, 'Invalid translation to correct:')
      Struct.new(:body).new(
        {choices: [{message: {content: 'Es soll den Geist der Bewegung einflößen.'}}]}.to_json
      )
    end

    expect(
      translator.repair_markup(
        source, invalid: invalid, issue: 'translation introduced foreign-script character: 注', tokens: {}, to: 'de'
      )
    ).to eq('Es soll den Geist der Bewegung einflößen.')
  end

  it 'removes an exact echoed source line from a repair response' do
    source = 'Emancipation in this case is liberation of permanent nature.'
    expect(Utils::HTTP).to receive(:post).and_return(
      Struct.new(:body).new(
        {
          choices: [
            {
              message: {
                content: "#{source}  \nEmanzipation in diesem Fall ist die Befreiung von dauerhafter Natur."
              }
            }
          ]
        }.to_json
      )
    )

    expect(
      translator.repair_markup(
        source, invalid: source, issue: 'translation left source prose unchanged', tokens: {}, to: 'de'
      )
    ).to eq('Emanzipation in diesem Fall ist die Befreiung von dauerhafter Natur.')
  end
end
