require 'spec_helper'
require_relative '../lib/language'

RSpec.describe Language do
  it 'detects language through Ollama JSON schema prompt' do
    text = 'Elaboracao e implementação de políticas públicas para a sociedade, com ações e decisões.'

    allow(AI::JSONSchema).to receive(:ask) do |backend:, task:, schema:, input:|
      expect(backend).to eq(AI::Ollama)
      expect(task).to eq(described_class::BOOK_PROMPT)
      expect(schema).to eq(described_class::BOOK_SCHEMA)
      expect(input).to include('políticas públicas')
      { 'lang' => 'pt', 'title' => '', 'author' => '', 'gender' => 'male' }
    end

    expect(described_class.detect([SymMash.new(text: text)])).to eq('pt')
  end

  it 'raises when language detection fails' do
    allow(AI::JSONSchema).to receive(:ask).and_raise('offline')

    expect { described_class.detect([SymMash.new(text: 'Texto em portugues')]) }.to raise_error(RuntimeError, 'language detection returned no valid result')
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

  it 'asks Ollama for title, author, gender, and language together' do
    allow(AI::JSONSchema).to receive(:ask) do |backend:, task:, schema:, input:|
      expect(backend).to eq(AI::Ollama)
      expect(task).to eq(described_class::BOOK_PROMPT)
      expect(schema).to eq(described_class::BOOK_SCHEMA)
      expect(input).to include('Mary Shelley')
      { 'lang' => 'en', 'title' => 'Frankenstein', 'author' => 'Mary Shelley', 'gender' => 'female' }
    end

    expect(described_class.book_metadata('Author: Mary Shelley')).to eq(
      'lang' => 'en', 'title' => 'Frankenstein', 'author' => 'Mary Shelley', 'gender' => 'female'
    )
    expect(described_class.author_gender('Author: Mary Shelley')).to eq('female')
    expect(described_class.detect([SymMash.new(text: 'Author: Mary Shelley')])).to eq('en')
  end

  it 'defaults author gender to male when detection fails' do
    allow(AI::JSONSchema).to receive(:ask).and_raise('offline')

    expect(described_class.book_metadata('Unknown author')).to eq(
      'lang' => '', 'title' => '', 'author' => '', 'gender' => 'male'
    )
    expect(described_class.author_gender('Unknown author')).to eq('male')
  end

  it 'puts the filename and pdf author in the prompt and omits cover objects' do
    input = described_class.book_input(
      { 'title' => 'A Solução Mineral', 'pdf_author' => 'GENESIS 2 CHURCH', 'cover' => Object.new, 'source_name' => 'MMS Jim Humble' },
      'Autor: James V. Humble',
      filename: 'MMS Jim Humble'
    )

    expect(input).to include('Filename: MMS Jim Humble')
    expect(input).to include('pdf_author')
    expect(input).to include('GENESIS 2 CHURCH')
    expect(input).to include('Sample pages:')
    expect(input).to include('James V. Humble')
    expect(input).not_to include('cover')
  end
end
