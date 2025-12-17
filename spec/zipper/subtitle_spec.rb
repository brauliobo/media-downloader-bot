require 'spec_helper'

RSpec.describe Zipper::Subtitle do
  it 'sanitizes ASS filename prefix to avoid ffmpeg filter graph separators' do
    prefix = "1 Detox Expert Reviews Paul Saladino's $3,000 Blood Wash (Inuspheresis)"
    safe = described_class.send(:safe_ass_prefix, prefix)

    expect(safe).to match(/\A[0-9A-Za-z_]+\z/)
    expect(safe).not_to include(',', "'", '$')
    expect(safe).not_to be_empty
  end
end


