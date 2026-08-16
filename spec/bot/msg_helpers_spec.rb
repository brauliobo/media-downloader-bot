require 'spec_helper'

RSpec.describe Bot::MsgHelpers do
  describe '.in_group?' do
    it 'distinguishes group chats from private chats' do
      group   = SymMash.new(from: {id: 123}, chat: {id: -456})
      private = SymMash.new(from: {id: 123}, chat: {id: 123})

      expect(described_class.in_group?(group)).to be(true)
      expect(described_class.in_group?(private)).to be(false)
    end
  end

  it 'escapes apostrophes without duplicating the text after them' do
    status = "How I've Increased HRV by 53% While Also Reducing RHR: dubbing: diarizing"

    expect(described_class.me(status)).to eq(
      "How I\\'ve Increased HRV by 53% While Also Reducing RHR: dubbing: diarizing"
    )
  end
end
