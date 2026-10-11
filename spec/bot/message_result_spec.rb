require 'rails_helper'

RSpec.describe Bot::MessageResult do
  it 'serializes message objects without calling to_h' do
    message_class = Struct.new(:id, :media_group_id) do
      def to_h = raise('unexpected to_h')
    end

    expect(described_class.dump(message_class.new(123, 456))).to eq(id: 123, media_group_id: 456)
  end

  it 'passes through values that are not message objects' do
    expect(described_class.dump('sent')).to eq('sent')
  end

  describe '.id' do
    it 'reads the id of an object, a mash or a plain hash' do
      expect(described_class.id(Struct.new(:id).new(1))).to eq(1)
      expect(described_class.id(SymMash.new(message_id: 2))).to eq(2)
      expect(described_class.id({ message_id: 3 })).to eq(3)
      expect(described_class.id({ id: 4 })).to eq(4)
    end

    it 'is none for what carries no id' do
      expect(described_class.id(nil)).to be_nil
      expect(described_class.id({})).to be_nil
    end
  end
end
