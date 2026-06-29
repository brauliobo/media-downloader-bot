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
    reference = 'This narrator voice reads the audiobook with calm, clear, natural pacing and keeps a steady tone across sentences.'

    allow(AI::JSONSchema).to receive(:ask) do |backend:, task:, schema:, input:|
      expect(backend).to eq(AI::Ollama)
      expect(task).to eq(described_class::REF_PROMPT)
      expect(schema).to eq(described_class::REF_SCHEMA)
      expect(input).to include('Language code: en')
      { 'text' => reference }
    end

    expect(described_class.voice_reference_text('en')).to eq(reference)
  end

  it 'asks Ollama for non-English voice reference text with a JSON schema' do
    reference = 'Esta voz narra o audiolivro com calma, clareza e ritmo natural, mantendo o mesmo tom em todas as frases.'

    allow(AI::JSONSchema).to receive(:ask) do |backend:, task:, schema:, input:|
      expect(backend).to eq(AI::Ollama)
      expect(task).to eq(described_class::REF_PROMPT)
      expect(schema).to eq(described_class::REF_SCHEMA)
      expect(input).to include('Language code: pt')
      { 'text' => reference }
    end

    expect(described_class.voice_reference_text('pt')).to eq(reference)
  end

  it 'uses a stable language fallback when voice reference text is too short' do
    allow(AI::JSONSchema).to receive(:ask).and_return({ 'text' => 'Ouça atentamente.' })

    expect(described_class.voice_reference_text('pt')).to eq(described_class::REF_FALLBACKS['pt'])
  end

  it 'asks Ollama for author gender and returns female when detected' do
    allow(AI::JSONSchema).to receive(:ask) do |backend:, task:, schema:, input:|
      expect(backend).to eq(AI::Ollama)
      expect(task).to eq(described_class::AUTHOR_PROMPT)
      expect(schema).to eq(described_class::AUTHOR_SCHEMA)
      expect(input).to include('Mary Shelley')
      { 'author' => 'Mary Shelley', 'gender' => 'female' }
    end

    expect(described_class.author_gender('Author: Mary Shelley')).to eq('female')
  end

  it 'defaults author gender to male when detection fails' do
    allow(AI::JSONSchema).to receive(:ask).and_raise('offline')

    expect(described_class.author_gender('Unknown author')).to eq('male')
  end
end
