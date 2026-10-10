require 'rails_helper'

RSpec.describe Audiobook::Source do
  it 'tells a Kindle reader address from any other path' do
    host = Audiobook::Parsers::Kindle::READ_HOSTS.first

    expect(described_class.kindle?("https://#{host}/?asin=B000")).to be(true)
    expect(described_class.kindle?('https://example.com/book.pdf')).to be(false)
    expect(described_class.kindle?('/tmp/book.pdf')).to be(false)
  end
end
