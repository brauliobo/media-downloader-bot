require 'spec_helper'
require_relative '../lib/language'

RSpec.describe Language do
  it 'detects language through Ollama JSON schema prompt' do
    text = 'Elaboracao e implementação de políticas públicas para a sociedade, com ações e decisões.'

    allow(AI::JSONSchema).to receive(:ask) do |backend:, task:, schema:, input:|
      expect(backend).to eq(AI::Ollama)
      expect(task).to eq(described_class::PROMPT_TEMPLATE)
      expect(schema).to eq(described_class::SCHEMA)
      expect(input).to include('políticas públicas')
      { 'lang' => 'pt' }
    end

    expect(described_class.detect([SymMash.new(text: text)])).to eq('pt')
  end

  it 'raises when language detection fails' do
    allow(AI::JSONSchema).to receive(:ask).and_raise('offline')

    expect { described_class.detect([SymMash.new(text: '???')]) }.to raise_error(RuntimeError, 'offline')
  end

  it 'uses the majority language across sampled text chunks' do
    stub_const('Language::CHUNK_SIZE', 40)
    text = [
      'English title page and a short publisher note.',
      'Este livro fala sobre saude intestinal em criancas e adultos.',
      'A maior parte do conteudo esta em portugues do Brasil.',
      'Os capitulos explicam alimentacao, sintomas e tratamento.',
    ].join("\n")

    allow(AI::JSONSchema).to receive(:ask) do |input:, **_kwargs|
      input.include?('English title') ? { 'lang' => 'en' } : { 'lang' => 'pt' }
    end

    expect(described_class.detect([SymMash.new(text: text)])).to eq('pt')
  end

  it 'splits enough content to avoid deciding from the first chunk only' do
    stub_const('Language::CHUNK_SIZE', 20)
    text = 'English preface. ' + ('Texto portugues. ' * 10)
    inputs = []

    allow(AI::JSONSchema).to receive(:ask) do |input:, **_kwargs|
      inputs << input
      { 'lang' => input.include?('English') ? 'en' : 'pt' }
    end

    expect(described_class.detect([SymMash.new(text: text)])).to eq('pt')
    expect(inputs.size).to be > 1
  end

  it 'raises on failed chunks instead of falling back to English' do
    stub_const('Language::CHUNK_SIZE', 20)
    calls = 0

    allow(AI::JSONSchema).to receive(:ask) do
      calls += 1
      raise 'temporary failure' if calls == 1

      { 'lang' => 'pt' }
    end

    expect do
      described_class.detect([SymMash.new(text: 'English intro. ' + ('Texto portugues. ' * 8))])
    end.to raise_error(RuntimeError, 'temporary failure')
  end

  it 'asks Ollama for English voice reference text with a JSON schema' do
    allow(AI::JSONSchema).to receive(:ask) do |backend:, task:, schema:, input:|
      expect(backend).to eq(AI::Ollama)
      expect(task).to eq(described_class::REF_PROMPT)
      expect(schema).to eq(described_class::REF_SCHEMA)
      expect(input).to include('Language code: en')
      { 'text' => 'This sentence anchors the audiobook narrator voice.' }
    end

    expect(described_class.voice_reference_text('en')).to eq('This sentence anchors the audiobook narrator voice.')
  end

  it 'asks Ollama for non-English voice reference text with a JSON schema' do
    allow(AI::JSONSchema).to receive(:ask) do |backend:, task:, schema:, input:|
      expect(backend).to eq(AI::Ollama)
      expect(task).to eq(described_class::REF_PROMPT)
      expect(schema).to eq(described_class::REF_SCHEMA)
      expect(input).to include('Language code: pt')
      { 'text' => 'Esta frase fixa a voz narradora do audiolivro.' }
    end

    expect(described_class.voice_reference_text('pt')).to eq('Esta frase fixa a voz narradora do audiolivro.')
  end
end
