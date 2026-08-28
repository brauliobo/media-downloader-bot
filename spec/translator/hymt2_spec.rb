require 'spec_helper'

RSpec.describe Translator::HyMT2 do
  subject(:backend) { Class.new { extend Translator::HyMT2 } }

  let(:response) do
    Struct.new(:body).new({
      choices: [{message: {content: "  É por conta da casa.\n"}}]
    }.to_json)
  end

  around do |example|
    original = ENV.values_at('HYMT2_HOST', 'HYMT2_MODEL')
    ENV['HYMT2_HOST']  = 'http://127.0.0.1:12002/'
    ENV['HYMT2_MODEL'] = 'Hy-MT2-7B-Q4_K_M.gguf'
    example.run
  ensure
    %w[HYMT2_HOST HYMT2_MODEL].zip(original).each do |key, value|
      value ? ENV[key] = value : ENV.delete(key)
    end
  end

  it 'translates a scalar into Brazilian Portuguese through the shared chat API' do
    expect(Utils::HTTP).to receive(:post) do |url, body, headers|
      payload = JSON.parse(body)
      expect(url).to eq('http://127.0.0.1:12002/v1/chat/completions')
      expect(headers).to eq('Content-Type' => 'application/json')
      expect(payload['model']).to eq('Hy-MT2-7B-Q4_K_M.gguf')
      expect(payload['temperature']).to eq(0)
      expect(payload.dig('messages', 0, 'content')).to include('Brazilian Portuguese', 'It is on the house.')
      response
    end

    expect(backend.translate('It is on the house.', from: 'en', to: 'pt')).to eq('É por conta da casa.')
  end

  it 'uses the surrounding peach thread context for array requests' do
    contexts = Queue.new
    allow(Utils::HTTP).to receive(:post) do |_url, _body, _headers|
      contexts << Thread.current[Enumerable::PEACH_THREADS]
      response
    end

    Enumerable.with_peach_threads(2) do
      backend.translate(%w[first second], from: 'en', to: 'es')
    end

    expect(2.times.map { contexts.pop }).to all(eq(2))
  end

  it 'translates arrays independently and preserves their order' do
    allow(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      source = JSON.parse(body).dig('messages', 0, 'content').lines.last.strip
      Struct.new(:body).new({choices: [{message: {content: "translated: #{source}"}}]}.to_json)
    end

    result = backend.translate(['first', 'second'], from: 'en', to: 'es')

    expect(result).to eq(['translated: first', 'translated: second'])
  end

  it 'requests complete spoken translations without shortening them to fit a duration' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompt = JSON.parse(body).dig('messages', 0, 'content')
      expect(prompt).to include(
        'faithfully and completely into natural spoken Brazilian Portuguese',
        'Do not summarize, condense, shorten, or omit any information.',
        'Preserve every distinct statement, qualifier, repetition, name, and number.',
        'Keep moving.'
      )
      expect(prompt).not_to include('concise', 'brief wording', 'seconds')
      response
    end

    backend.translate_for_dubbing('Keep moving.', from: 'en', to: 'pt')
  end

  it 'provides adjacent dialogue to disambiguate dubbing translations' do
    prompts = []
    allow(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      prompts << JSON.parse(body).dig('messages', 0, 'content')
      response
    end

    backend.translate_for_dubbing(
      [
        'My main objective is to gain more experience.',
        'I think those goals were very smart.',
        'I hope to earn between 35,000 and 38,000 a year.',
      ],
      from: 'en',
      to:   'pt'
    )

    prompt = prompts.find { |value| value.include?("Main dialogue:\nI think those goals were very smart.") }
    expect(prompt).to include(
      'Previous: My main objective is to gain more experience.',
      'Next: I hope to earn between 35,000 and 38,000 a year.',
      'Translate only the main dialogue, not the context.'
    )
  end

  it 'uses the ISO language name for non-Portuguese targets' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      expect(JSON.parse(body).dig('messages', 0, 'content')).to include('Spanish')
      response
    end

    backend.translate('Hello.', from: 'en', to: 'es')
  end

  it 'retries EOF from the translation backend' do
    calls = 0
    agent = stub_http_client
    allow(Kernel).to receive(:sleep)
    allow(agent).to receive(:post) do
      calls += 1
      raise EOFError if calls == 1

      response
    end

    expect(backend.translate('Hello.', from: 'en', to: 'es')).to eq('É por conta da casa.')
    expect(calls).to eq(2)
  end
end
