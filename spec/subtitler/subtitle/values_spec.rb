require 'rails_helper'

RSpec.describe Subtitler::Subtitle::Values do
  it 'reads times as finite numbers' do
    expect(described_class.number(2, 'start')).to eq(2.0)
    expect(described_class.milliseconds(1500, 't0_ms')).to eq(1.5)
    expect { described_class.number(Float::INFINITY, 'start') }.to raise_error(ArgumentError, /start must be finite/)
    expect { described_class.number(nil, 'start') }.to raise_error(TypeError)
  end

  it 'takes a time as seconds or as a timestamp' do
    expect(described_class.time_value(1.5, 'from')).to eq(1.5)
    expect(described_class.time_value('00:00:02.500', 'from')).to eq(2.5)
    expect { described_class.time_value('soon', 'from') }.to raise_error(ArgumentError, /invalid from timestamp/)
  end

  it 'hands back frozen text and lists so a stored value cannot change from outside' do
    expect(described_class.text(nil)).to eq('')
    expect(described_class.text(+'a')).to be_frozen
    expect(described_class.string_or_nil(nil)).to be_nil
    expect(described_class.list(nil)).to eq([])
    expect(described_class.list([1])).to be_frozen
  end

  it 'freezes a metadata tree and thaws a copy of it' do
    copy = described_class.immutable_copy('cues' => [+'a'])

    expect(copy).to be_frozen
    expect(copy['cues'].first).to be_frozen
    expect(described_class.mutable_copy(copy)['cues'].first).not_to be_frozen
  end

  it 'says what is wrong with a JSON document that does not parse' do
    expect { described_class.parse_json_object('{') }.to raise_error(ArgumentError, /invalid subtitle JSON/)
    expect(described_class.parse_json_object('{"a":1}')).to eq('a' => 1)
  end
end
