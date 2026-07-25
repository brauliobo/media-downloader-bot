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
        'Output each placeholder exactly once without adding, omitting, duplicating, or renumbering it: __P0001__.',
        '__P0001__'
      )
      Struct.new(:body).new({choices: [{message: {content: "  A palavra __P0001__ significa felicidade.\n"}}]}.to_json)
    end

    expect(translator.translate_markup('The word __P0001__ means bliss.', to: 'pt')).to eq(
      'A palavra __P0001__ significa felicidade.'
    )
  end

  it 'enumerates distinct placeholder numbers' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        'Output each placeholder exactly once without adding, omitting, duplicating, or renumbering it: ' \
        '__P0002__, __P0001__.'
      )
      Struct.new(:body).new({choices: [{message: {content: '__P0002__ Buda __P0001__'}}]}.to_json)
    end

    expect(translator.translate_markup('__P0002__ Buddha __P0001__', to: 'pt')).to eq(
      '__P0002__ Buda __P0001__'
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

  it 'retranslates with semantic context without changing placeholder multiplicity' do
    source = 'where __P0002__ is present dominant __P0003__ is ordinary and __P0004__ is negligible.'
    corrected = 'onde __P0002__ é dominante, __P0003__ é comum e __P0004__ é insignificante.'
    tokens = {
      '__P0002__' => 'Tamogun&#x301;a',
      '__P0003__' => 'Rajogun&#x301;a',
      '__P0004__' => 'sattvagun&#x301;a'
    }
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        source, '__P0002__ = Tamoguna', '__P0003__ = Rajoguna', '__P0004__ = sattvaguna'
      )
      Struct.new(:body).new({choices: [{message: {content: corrected}}]}.to_json)
    end

    expect(translator.repair_markup(source, tokens: tokens, to: 'pt')).to eq(corrected)
  end
end
