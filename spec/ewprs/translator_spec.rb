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
      expect(payload.dig('messages', 0, 'content')).to include(
        'Brazilian Portuguese',
        'Preserve every sentence and line break',
        'Choose one direct translation; do not output alternatives, annotations, or parenthetical variants.',
        'including unmatched delimiters: "("=0, ")"=0, "["=0, "]"=0, "{"=2, "}"=2',
        'Preserve exactly these placeholder occurrences, including every repeated entry, without translating or ' \
        'renumbering them: {{EWPRS_P1}}. Do not append this list to the translation.',
        '{{EWPRS_P1}}'
      )
      Struct.new(:body).new(
        {choices: [{message: {content: "  A palavra {{EWPRS_P1}} significa felicidade.\n"}}]}.to_json
      )
    end

    expect(translator.translate_markup('The word __P0001__ means bliss.', to: 'pt')).to eq(
      'A palavra __P0001__ significa felicidade.'
    )
  end

  it 'uses explicit jobs as distributed request concurrency' do
    expect(described_class.new(jobs: '40').jobs).to eq(40)
  end

  it 'enumerates every placeholder occurrence' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        'Preserve exactly these placeholder occurrences, including every repeated entry, without translating or ' \
        'renumbering them: {{EWPRS_P2}}, {{EWPRS_P1}}, {{EWPRS_P2}}. ' \
        'Do not append this list to the translation.'
      )
      Struct.new(:body).new(
        {choices: [{message: {content: '{{EWPRS_P2}} Buda {{EWPRS_P1}} {{EWPRS_P2}}'}}]}.to_json
      )
    end

    expect(translator.translate_markup('__P0002__ Buddha __P0001__ __P0002__', to: 'pt')).to eq(
      '__P0002__ Buda __P0001__ __P0002__'
    )
  end

  it 'protects HTML character references from the translation model' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        '{{EWPRS_E1}}The word{{EWPRS_E2}} {{EWPRS_E3}} another word {{EWPRS_E4}}:',
        '{{EWPRS_E1}}, {{EWPRS_E2}}, {{EWPRS_E3}}, {{EWPRS_E4}}'
      )
      expect(prompt).not_to include('&ldquo;', '&rdquo;', '&ndash;', '&nbsp')
      Struct.new(:body).new(
        {
          choices: [
            {message: {content: '{{EWPRS_E1}}A palavra{{EWPRS_E2}} {{EWPRS_E3}} outra palavra {{EWPRS_E4}}:'}}
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
        '{{EWPRS_E1}}One{{EWPRS_E2}} and {{EWPRS_E3}}two{{EWPRS_E4}}',
        '{{EWPRS_E1}}, {{EWPRS_E2}}, {{EWPRS_E3}}, {{EWPRS_E4}}'
      )
      Struct.new(:body).new(
        {
          choices: [
            {message: {content: '{{EWPRS_E1}}Um{{EWPRS_E2}} e {{EWPRS_E3}}dois{{EWPRS_E4}}'}}
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
        source.gsub('__P0002__', '{{EWPRS_P2}}').gsub('__P0003__', '{{EWPRS_P3}}')
          .gsub('__P0004__', '{{EWPRS_P4}}'),
        invalid.gsub('__P0002__', '{{EWPRS_P2}}').gsub('__P0003__', '{{EWPRS_P3}}')
          .gsub('__P0004__', '{{EWPRS_P4}}'), issue,
        'Translate every English prose word outside placeholders; do not copy source-language prose.',
        'Copy every placeholder literally; never replace it with its meaning.',
        '{{EWPRS_P2}} = Tamoguna', '{{EWPRS_P3}} = Rajoguna', '{{EWPRS_P4}} = sattvaguna'
      )
      encoded = corrected.gsub('__P0002__', '{{EWPRS_P2}}').gsub('__P0003__', '{{EWPRS_P3}}')
        .gsub('__P0004__', '{{EWPRS_P4}}')
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
        source.gsub('__P0001__', '{{EWPRS_P1}}')
      )
      expect(prompt).not_to include('Invalid translation to correct:')
      Struct.new(:body).new(
        {choices: [{message: {content: 'Borrifar água como uma fonte também se chama {{EWPRS_P1}}.'}}]}.to_json
      )
    end

    expect(
      translator.repair_markup(
        source, invalid: source, issue: 'translation retained a long source-language span',
        tokens: {'__P0001__' => 'karapatrika'}, to: 'pt'
      )
    ).to eq('Borrifar água como uma fonte também se chama __P0001__.')
  end
end
