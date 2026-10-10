require 'rails_helper'

RSpec.describe Audiobook::ListMark do
  describe '.enumerated?' do
    it 'recognises numbered, lettered and bulleted entries' do
      expect(described_class.enumerated?('1. Introducción y explicación')).to be(true)
      expect(described_class.enumerated?('b. Raw butter')).to be(true)
      expect(described_class.enumerated?('♦ Duche vaginal: use dois copos')).to be(true)
      expect(described_class.enumerated?('E. coli grows fast')).to be(false)
      expect(described_class.enumerated?('1990 was the year')).to be(false)
    end
  end

  describe '.strip_bullet' do
    it 'drops a bullet glyph but keeps the label it follows' do
      expect(described_class.strip_bullet('► MMS1 is activated MMS.')).to eq('MMS1 is activated MMS.')
      expect(described_class.strip_bullet('13.) ► MMS is a 22.4% solution')).to eq('13.) MMS is a 22.4% solution')
      expect(described_class.strip_bullet('No se debe mezclar')).to eq('No se debe mezclar')
    end
  end
end
