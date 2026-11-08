require 'rails_helper'

RSpec.describe Language::Code do
  it 'reduces codes, regional variants and English names to the ISO 639-1 code' do
    %w[pt pt-BR pt_br por Portuguese PORTUGUESE].each { |lang| expect(described_class.normalize(lang)).to eq('pt'), lang }
  end

  it 'says nothing about what is not a language' do
    expect(described_class.normalize(nil)).to be_nil
    expect(described_class.normalize('xx')).to be_nil
  end

  it 'knows the languages written without spaces between words' do
    %w[zh zh-CN Chinese ja Japanese th].each { |lang| expect(described_class.spaceless?(lang)).to be(true), lang }
    %w[pt en ko].each { |lang| expect(described_class.spaceless?(lang)).to be(false), lang }
    expect(described_class.spaceless?(nil)).to be(false)
  end
end
