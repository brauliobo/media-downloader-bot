require 'spec_helper'

RSpec.describe Processors::LanguageOpts do
  it 'copies lang= onto subtitle and audio language' do
    opts = SymMash.new(lang: 'pt', slang: 'en')

    described_class.expand(opts)

    expect(opts).to include(lang: 'pt', slang: 'pt', alang: 'pt')
  end

  it 'selects caption, dub, lang, then subtitle language' do
    [
      [{clang: 'es', dub_lang: 'pt', lang: 'fr', slang: 'de'}, 'es'],
      [{dub_lang: 'pt', lang: 'fr', slang: 'de'}, 'pt'],
      [{lang: 'pt', slang: 'de'}, 'pt'],
      [{slang: 'pt'}, 'pt'],
      [{}, 'en'],
    ].each do |opts, expected|
      fallback = opts.empty? ? 'en' : nil
      expect(described_class.from(SymMash.new(opts), fallback)).to eq(expected)
    end
  end
end
