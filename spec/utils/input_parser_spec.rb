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

  it 'keeps cut options after youtube playlist watch urls' do
    parsed = described_class.parse('https://www.youtube.com/watch?v=ceWwMJN5Ou0&list=TLPQMDMwNzIwMjbHKJx1-gwUng&index=13 ss=14:57 to=20:00')

    expect(parsed.url.to_s).to eq('https://www.youtube.com/watch?v=ceWwMJN5Ou0&list=TLPQMDMwNzIwMjbHKJx1-gwUng&index=13')
    expect(parsed.opts).to eq('ss' => '14:57', 'to' => '20:00')
  end

  it 'normalizes bare urls before parsing' do
    parsed = described_class.parse('x.com/i/status/2070518837150167314 audio')

    expect(parsed.url.to_s).to eq('https://x.com/i/status/2070518837150167314')
    expect(parsed.opts).to eq('audio' => 1)
  end

  it 'builds one url input with trailing option lines' do
    inputs = described_class.url_inputs(['Cloooud |🇺🇦', 'x.com/i/status/2070518837150167314', 'audio'])

    expect(inputs).to eq(['x.com/i/status/2070518837150167314 audio'])
  end

  it 'builds separate inputs for multiple url lines' do
    inputs = described_class.url_inputs(['https://example.com/a audio', 'https://example.com/b video'])

    expect(inputs).to eq(['https://example.com/a audio', 'https://example.com/b video'])
  end

  it 'applies first-line options to each url input' do
    inputs = described_class.url_inputs(['audio speed=1.2', 'https://example.com/a', 'https://example.com/b speed=1.5'])

    expect(inputs).to eq(['https://example.com/a audio speed=1.2', 'https://example.com/b audio speed=1.2 speed=1.5'])
  end

  it 'groups following option lines with each url input' do
    inputs = described_class.url_inputs(['audio', 'https://example.com/a', 'speed=1.2', 'https://example.com/b', 'speed=1.5'])

    expect(inputs).to eq(['https://example.com/a audio speed=1.2', 'https://example.com/b audio speed=1.5'])
  end

  it 'does not treat a title line as base options' do
    inputs = described_class.url_inputs(['Cloooud |🇺🇦', 'https://example.com/a', 'audio'])

    expect(inputs).to eq(['https://example.com/a audio'])
  end

  it 'uses captions as message input when text is empty' do
    msg = SymMash.new(text: '', caption: "audio\nspeed=1.2")

    expect(described_class.message_text(msg)).to eq("audio\nspeed=1.2")
    expect(described_class.message_lines(msg)).to eq(['audio', 'speed=1.2'])
  end
end
