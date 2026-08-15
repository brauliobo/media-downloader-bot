require 'spec_helper'

RSpec.describe Subtitler::Ass do
  it 'parses compact comma markers as highlights without leaving marker prose' do
    vtt = <<~VTT
      WEBVTT

      00:00,000 --> 00:02,000
      First <00:01,000>second
    VTT

    dialogues = described_class.from_vtt(vtt).lines.grep(/^Dialogue:/)

    expect(dialogues.size).to eq(2)
    expect(dialogues.join).to include('First', 'second')
    expect(dialogues.join).not_to match(/<\d{2}:\d{2}/)
  end

  it 'carries rounded centiseconds into seconds' do
    expect(described_class.ass_time(0.999)).to eq('0:00:01.00')
    expect(described_class.ass_time(1.999)).to eq('0:00:02.00')
  end
end
