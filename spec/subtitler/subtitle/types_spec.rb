require 'rails_helper'

RSpec.describe Subtitler::Subtitle::Types do
  it 'checks the type of what a subtitle is given' do
    expect { described_class.string(1, 'text') }.to raise_error(TypeError, /text must be a String/)
    expect { described_class.number('1', 'start') }.to raise_error(TypeError, /start must be Numeric/)
    expect { described_class.number(Float::INFINITY, 'start') }.to raise_error(ArgumentError, /finite/)
    expect { described_class.typed_array([1], String, 'tokens') }.to raise_error(TypeError, /only String/)
  end

  it 'hands back frozen copies so a stored value cannot change from outside' do
    source = { 'cues' => [+'a'] }
    copy   = described_class.immutable_hash(source, 'metadata')

    expect(copy).to be_frozen
    expect(copy['cues'].first).to be_frozen
    expect(described_class.mutable_copy(copy)['cues'].first).not_to be_frozen
  end

  it 'reads milliseconds as seconds' do
    expect(described_class.milliseconds(1500, 't0_ms')).to eq(1.5)
  end
end
