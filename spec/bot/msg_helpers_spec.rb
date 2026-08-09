require 'spec_helper'

RSpec.describe Bot::MsgHelpers do
  it 'escapes apostrophes without duplicating the text after them' do
    status = "How I've Increased HRV by 53% While Also Reducing RHR: dubbing: diarizing"

    expect(described_class.me(status)).to eq(
      "How I\\'ve Increased HRV by 53% While Also Reducing RHR: dubbing: diarizing"
    )
  end
end
