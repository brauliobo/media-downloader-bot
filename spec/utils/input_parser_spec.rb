require 'spec_helper'

RSpec.describe Utils::InputParser do
  it 'parses a leading url and following options' do
    parsed = described_class.parse('https://example.com/v speed=1.2 audio')

    expect(parsed.url.to_s).to eq('https://example.com/v')
    expect(parsed.opts).to eq('speed' => '1.2', 'audio' => 1)
  end

  it 'parses the first url from shared text' do
    parsed = described_class.parse('Check this https://example.com/v speed=1.2')

    expect(parsed.url.to_s).to eq('https://example.com/v')
    expect(parsed.opts).to eq('speed' => '1.2')
  end

  it 'normalizes bare urls before parsing' do
    parsed = described_class.parse('x.com/i/status/2070518837150167314 audio')

    expect(parsed.url.to_s).to eq('https://x.com/i/status/2070518837150167314')
    expect(parsed.opts).to eq('audio' => 1)
  end
end
