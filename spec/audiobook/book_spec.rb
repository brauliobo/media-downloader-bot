require 'spec_helper'
require_relative '../../lib/audiobook/book'

RSpec.describe Audiobook::Book do
  describe '.detect_language' do
    it 'uses explicit language options before automatic detection' do
      expect(Language).not_to receive(:detect)

      lang = described_class.detect_language('/does/not/exist.pdf', opts: SymMash.new(slang: 'pt'))

      expect(lang).to eq('pt')
    end
  end
end
