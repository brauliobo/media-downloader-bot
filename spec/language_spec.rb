require 'spec_helper'
require_relative '../lib/language'

RSpec.describe Language do
  it 'detects language through OpenCode JSON schema prompt' do
    text = 'Elaboracao e implementação de políticas públicas para a sociedade, com ações e decisões.'

    allow(AI::JSONSchema).to receive(:ask) do |backend:, task:, schema:, input:|
      expect(backend).to eq(AI::OpenCode)
      expect(task).to eq(described_class::PROMPT_TEMPLATE)
      expect(schema).to eq(described_class::SCHEMA)
      expect(input).to include('políticas públicas')
      { 'lang' => 'pt' }
    end

    expect(described_class.detect([SymMash.new(text: text)])).to eq('pt')
  end

  it 'falls back to English when language detection fails' do
    allow(AI::JSONSchema).to receive(:ask).and_raise('offline')

    expect(described_class.detect([SymMash.new(text: '???')])).to eq('en')
  end

  it 'asks OpenCode for English voice reference text with a JSON schema' do
    allow(AI::JSONSchema).to receive(:ask) do |backend:, task:, schema:, input:|
      expect(backend).to eq(AI::OpenCode)
      expect(task).to eq(described_class::REF_PROMPT)
      expect(schema).to eq(described_class::REF_SCHEMA)
      expect(input).to include('Language code: en')
      { 'text' => 'This sentence anchors the audiobook narrator voice.' }
    end

    expect(described_class.voice_reference_text('en')).to eq('This sentence anchors the audiobook narrator voice.')
  end

  it 'asks OpenCode for non-English voice reference text with a JSON schema' do
    allow(AI::JSONSchema).to receive(:ask) do |backend:, task:, schema:, input:|
      expect(backend).to eq(AI::OpenCode)
      expect(task).to eq(described_class::REF_PROMPT)
      expect(schema).to eq(described_class::REF_SCHEMA)
      expect(input).to include('Language code: pt')
      { 'text' => 'Esta frase fixa a voz narradora do audiolivro.' }
    end

    expect(described_class.voice_reference_text('pt')).to eq('Esta frase fixa a voz narradora do audiolivro.')
  end
end
