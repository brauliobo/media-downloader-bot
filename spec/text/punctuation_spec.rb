require 'rails_helper'

RSpec.describe Text::Punctuation do
  describe '.closes?' do
    it 'does not close a sentence on an honorific, an initial or a list label' do
      expect(described_class.closes?('O relato é de Dra. Antje Oswald, Dr.')).to be(false)
      expect(described_class.closes?('drugs are able to make it into the U.')).to be(false)
      expect(described_class.closes?('a.')).to be(false)
    end

    it 'still closes a sentence on an ordinary stop' do
      expect(described_class.closes?('Ele saiu de casa.')).to be(true)
      expect(described_class.closes?('Quem chegou?')).to be(true)
    end
  end

  it 'tells where a line ends its sentence or only its clause' do
    expect(described_class.terminal?('Ele saiu."')).to be(true)
    expect(described_class.terminal?('Ele saiu,')).to be(false)
    expect(described_class.clause_end?('Ele saiu,')).to be(true)
    expect(described_class.clause_end?('Ele saiu')).to be(false)
  end

  it 'tells text with nothing to say' do
    ['.', '...', ' . … ', '"..."', '—', '***'].each { |text| expect(described_class.only?(text)).to be(true), text }
    expect(described_class.only?('Olá...')).to be(false)
  end

  it 'tells an ellipsis that pauses' do
    expect(described_class.ellipsis?('Wait...')).to be(true)
    expect(described_class.ellipsis?('Wait.')).to be(false)
  end
end
