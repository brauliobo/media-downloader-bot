require 'rails_helper'

RSpec.describe Audiobook::Contents do
  describe '.strip_leaders' do
    it 'removes leader runs and the page number they point at' do
      expect(described_class.strip_leaders('H AITI ........................ 9')).to eq('H AITI')
      expect(described_class.strip_leaders('Chapter I.……………The Hermetic Philosophy.'))
        .to eq('Chapter I. The Hermetic Philosophy.')
    end

    it 'leaves ordinary prose untouched' do
      expect(described_class.strip_leaders('Wait... the answer is 42')).to eq('Wait... the answer is 42')
    end

    it 'drops a marker tag a scanned page number left on the entry' do
      expect(described_class.strip_leaders('Calvicie ........... 19⟦2⟧')).to eq('Calvicie')
    end
  end
end
