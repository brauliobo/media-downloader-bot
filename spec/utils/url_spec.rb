require 'spec_helper'

RSpec.describe Utils::Url do
  it 'adds https to bare domains without changing complete urls' do
    expect(described_class.normalize('x.com/i/status/1')).to eq('https://x.com/i/status/1')
    expect(described_class.normalize('https://x.com/i/status/1')).to eq('https://x.com/i/status/1')
  end

  it 'parses query and fragment components without dropping the scheme' do
    uri = described_class.parse('https://example.com/photo?album=1#cover')

    expect(uri.host).to eq('example.com')
    expect(uri.query).to eq('album=1')
    expect(uri.fragment).to eq('cover')
    expect(uri.to_s).to eq('https://example.com/photo?album=1#cover')
  end

  it 'only treats complete domain tokens as urls' do
    expect(described_class.token?('caption')).to be(false)
    expect(described_class.token?('example.com/photo.jpg')).to be_truthy
  end
end
