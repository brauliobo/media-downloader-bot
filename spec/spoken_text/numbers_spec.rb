require 'rails_helper'

RSpec.describe SpokenText::Numbers do
  def say(text, lang = 'pt') = described_class.call(text, lang)

  it 'spells grouped and plain integers' do
    expect(say('mais de 7.000 missões')).to eq('mais de sete mil missões')
    expect(say('em 2026')).to eq('em dois mil e vinte e seis')
    expect(say('1.234.567 pessoas')).to eq('um milhão duzentos e trinta e quatro mil quinhentos e sessenta e sete pessoas')
    expect(say("7 000 homens")).to eq('sete mil homens')
  end

  it 'spells a number joined to a word by a hyphen' do
    expect(say('COVID-19')).to eq('COVID-dezenove')
  end

  it 'spells decimals in either notation' do
    expect(say('3,5 metros')).to eq('três inteiros e cinco décimos metros')
    expect(say('3.5 metros')).to eq('três inteiros e cinco décimos metros')
    expect(say('1.234,5')).to eq('mil duzentos e trinta e quatro inteiros e cinco décimos')
  end

  it 'spells ordinals with the gender of the mark' do
    expect(say('a 414ª Brigada')).to eq('a quadringentésima décima quarta Brigada')
    expect(say('o 1º lugar')).to eq('o primeiro lugar')
    expect(say('a 2.ª vez')).to eq('a segunda vez')
  end

  it 'spells numbers for any language with a speller' do
    expect(say('7.000 missões', 'es')).to eq('siete mil missões')
    expect(say("7 000", 'fr-FR')).to eq('sept mille')
  end

  it 'leaves what is not a quantity alone' do
    ['mp3', '4K', '10h', '12/10/2026', '10:30', 'v1.2.3', '007', '12345678901234567890'].each do |text|
      expect(say(text)).to eq(text)
    end
  end

  it 'leaves ordinals alone where the speller has none' do
    expect(say('der 2º Platz', 'de')).to eq('der 2º Platz')
  end

  it 'leaves languages the engine normalizes, and unknown ones, untouched' do
    %w[en zh ja xx].each { |lang| expect(say('7.000 e 414ª', lang)).to eq('7.000 e 414ª') }
    expect(say('7.000', nil)).to eq('7.000')
  end
end
