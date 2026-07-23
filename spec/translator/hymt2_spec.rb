require 'spec_helper'

RSpec.describe Translator::HyMT2 do
  subject(:backend) { Class.new { extend Translator::HyMT2 } }

  let(:response) do
    Struct.new(:body).new({
      choices: [{message: {content: "  É por conta da casa.\n"}}]
    }.to_json)
  end

  around do |example|
    original = ENV.values_at('HYMT2_HOST', 'HYMT2_MODEL', 'HYMT2_CONCURRENCY')
    ENV['HYMT2_HOST']        = 'http://127.0.0.1:12002/'
    ENV['HYMT2_MODEL']       = 'Hy-MT2-7B-Q4_K_M.gguf'
    ENV['HYMT2_CONCURRENCY'] = '1'
    example.run
  ensure
    %w[HYMT2_HOST HYMT2_MODEL HYMT2_CONCURRENCY].zip(original).each do |key, value|
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

  it 'translates arrays independently and preserves their order' do
    allow(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      source = JSON.parse(body).dig('messages', 0, 'content').lines.last.strip
      Struct.new(:body).new({choices: [{message: {content: "translated: #{source}"}}]}.to_json)
    end

    result = backend.translate(['first', 'second'], from: 'en', to: 'es')

    expect(result).to eq(['translated: first', 'translated: second'])
  end

  it 'uses the ISO language name for non-Portuguese targets' do
    expect(Utils::HTTP).to receive(:post) do |_url, body, _headers|
      expect(JSON.parse(body).dig('messages', 0, 'content')).to include('Spanish')
      response
    end

    backend.translate('Hello.', from: 'en', to: 'es')
  end
end
