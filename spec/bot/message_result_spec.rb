require 'spec_helper'

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
end
