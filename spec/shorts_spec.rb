require 'spec_helper'
require_relative '../lib/shorts'

RSpec.describe Shorts do
  it 'generates cuts through the shared JSON schema helper' do
    captured = nil
    allow(AI::JSONSchema).to receive(:ask) do |**kwargs|
      captured = kwargs
      [{ 'start' => '00:00:01', 'end' => '00:00:45', 'title' => 'Great Moment' }]
    end

    cuts = described_class.generate_cuts_from_srt('1\n00:00:01 --> 00:00:45\nHello world')

    expect(cuts).to eq([{ start: '00:00:01', end: '00:00:45', title: 'Great Moment' }])
    expect(captured[:backend]).to eq(AI::Codex)
    expect(captured[:schema]).to eq(described_class::CUT_SCHEMA)
    expect(captured[:input]).to include('Transcript (SRT):')
  end

  it 'generates one title through the shared JSON schema helper' do
    captured = nil
    allow(AI::JSONSchema).to receive(:ask) do |**kwargs|
      captured = kwargs
      { 'title' => 'Concise Segment Title' }
    end

    title = described_class.generate_title_for_segment_slice("WEBVTT\n\n00:00:01 --> 00:00:05\nSome useful excerpt", language: 'pt')

    expect(title).to eq('Concise Segment Title')
    expect(captured[:backend]).to eq(AI::Codex)
    expect(captured[:schema]).to eq(described_class::TITLE_SCHEMA)
    expect(captured[:task]).to include('Generate the title in: pt')
  end
end
