require 'spec_helper'
require_relative '../lib/shorts'

RSpec.describe Shorts do
  it 'generates cuts through the shared JSON schema helper' do
    captured = nil
    allow(AI::JSONSchema).to receive(:ask) do |**kwargs|
      captured = kwargs
      [{ 'start' => '00:00:01', 'end' => '00:00:45', 'title' => 'Great Moment' }]
    end

    subtitle = Subtitler::Subtitle.from_srt("1\n00:00:01,000 --> 00:00:45,000\nHello world\n")
    cuts = described_class.generate_cuts(subtitle)

    expect(cuts).to eq([
      described_class::Cut.new(start: '00:00:01', finish: '00:00:45', title: 'Great Moment'),
    ])
    expect(captured[:backend]).to eq(AI::Ollama)
    expect(captured[:model]).to eq(described_class::MODEL)
    expect(captured[:schema]).to eq(described_class::CUT_SCHEMA)
    expect(captured[:input]).to include('Transcript (SRT):')
  end

  it 'generates one title through the shared JSON schema helper' do
    captured = nil
    allow(AI::JSONSchema).to receive(:ask) do |**kwargs|
      captured = kwargs
      { 'title' => 'Concise Segment Title' }
    end

    source = Subtitler::Subtitle.from_vtt(
      "WEBVTT\n\n00:00:01.000 --> 00:00:05.000\nSome useful excerpt\n\n" \
      "00:00:06.000 --> 00:00:08.000\nOutside excerpt\n"
    )
    title = described_class.generate_title(source.slice(from: 1, to: 5), language: 'pt')

    expect(title).to eq('Concise Segment Title')
    expect(captured[:backend]).to eq(AI::Ollama)
    expect(captured[:schema]).to eq(described_class::TITLE_SCHEMA)
    expect(captured[:task]).to include('Generate the title in: pt')
    expect(captured[:input]).to include('Some useful excerpt')
    expect(captured[:input]).not_to include('Outside excerpt', 'WEBVTT', '-->')
  end

  it 'validates typed cuts and drops malformed AI cuts at ingress' do
    subtitle = Subtitler::Subtitle.from_srt("1\n00:00:01,000 --> 00:00:45,000\nHello world\n")
    allow(AI::JSONSchema).to receive(:ask).and_return([
      { 'start' => '00:00:10', 'end' => '00:00:05', 'title' => 'Backwards' },
      { 'start' => 'bad', 'end' => '00:00:20', 'title' => 'Malformed' },
    ])

    expect(described_class.generate_cuts(subtitle)).to eq([])
    expect do
      described_class::Cut.new(start: '00:00:10', finish: '00:00:05', title: 'Backwards')
    end.to raise_error(ArgumentError, 'short cut is malformed')
  end
end
