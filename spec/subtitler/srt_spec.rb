require 'spec_helper'

RSpec.describe Subtitler::SRT do
  it 'removes an entire cue when a content line is a dotted numeric noise sequence' do
    srt = <<~SRT
      1
      00:00:00,000 --> 00:00:01,000
      Keep before noise
      1 . 2 . 3 . 4

      2
      00:00:01,000 --> 00:00:02,000
      Spoken text
    SRT

    expect(described_class.filter_noise(srt)).to eq(
      "2\n00:00:01,000 --> 00:00:02,000\nSpoken text\n"
    )
  end

  it 'keeps dotted prose, version-like text, and sequences shorter than four numbers' do
    srt = <<~SRT
      1
      00:00:00,000 --> 00:00:01,000
      Version 1.2.3.4 remains

      2
      00:00:01,000 --> 00:00:02,000
      1.2.3

      3
      00:00:02,000 --> 00:00:03,000
      Ordinary speech...
    SRT

    expect(described_class.filter_noise(srt)).to eq(srt)
  end

  it 'recognizes compact numeric noise and CRLF cue separators' do
    srt = "1\r\n00:00:00,000 --> 00:00:01,000\r\n1.2.3.4\r\n\r\n" \
          "2\r\n00:00:01,000 --> 00:00:02,000\r\nKept\r\n"

    expect(described_class.filter_noise(srt)).to eq(
      "2\r\n00:00:01,000 --> 00:00:02,000\r\nKept\r\n"
    )
  end
end
