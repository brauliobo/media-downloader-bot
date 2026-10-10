require 'rails_helper'

RSpec.describe Audiobook::Languages do
  it 'reads the speech language from slang first, then lang' do
    expect(described_class.speech(SymMash.new(slang: 'es', lang: 'pt'))).to eq('es')
    expect(described_class.speech(SymMash.new(lang: ' pt '))).to eq('pt')
    expect(described_class.speech(nil)).to be_nil
  end

  it 'reads a source language only when it differs from the speech target' do
    expect(described_class.source(SymMash.new(alang: 'en', slang: 'pt'))).to eq('en')
    expect(described_class.source(SymMash.new(alang: 'pt', lang: 'pt'))).to be_nil
  end
end
