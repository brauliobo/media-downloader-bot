require 'rails_helper'

RSpec.describe Language::Name do
  it 'names a language in English from any way of writing it' do
    expect(described_class.english('pt-BR')).to eq('Portuguese')
    expect(described_class.english('es')).to eq('Spanish')
    expect(described_class.english('JA')).to eq('Japanese')
  end

  it 'falls back to what it was given when the language is unknown' do
    expect(described_class.english('XX')).to eq('xx')
  end

  it 'names the variant a translation is written in' do
    expect(described_class.target('pt')).to eq('Brazilian Portuguese')
    expect(described_class.target('zh')).to eq('Simplified Chinese')
    expect(described_class.target('de')).to eq('German')
  end
end
