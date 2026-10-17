require 'rails_helper'

RSpec.describe Audiobook::Source do
  %w[odt doc docx].each do |ext|
    it "reads a .#{ext} text as the PDF LibreOffice makes of it" do
      Dir.mktmpdir do |dir|
        path = FileUtils.cp(Rails.root.join("spec/fixtures/audiobook/office-sample.#{ext}"), dir).then { File.join(dir, "office-sample.#{ext}") }

        data = SymMash.wrap(described_class.parse(path))

        expect(File).to exist(File.join(dir, 'office-sample.pdf'))
        expect(data.to_json).to include('quick brown fox')
      end
    end
  end

  it 'tells a Kindle reader address from any other path' do
    host = Audiobook::Parsers::Kindle::READ_HOSTS.first

    expect(described_class.kindle?("https://#{host}/?asin=B000")).to be(true)
    expect(described_class.kindle?('https://example.com/book.pdf')).to be(false)
    expect(described_class.kindle?('/tmp/book.pdf')).to be(false)
  end
end
