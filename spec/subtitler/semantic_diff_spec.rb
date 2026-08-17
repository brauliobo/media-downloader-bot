require 'json'
require 'open3'
require 'rbconfig'
require 'tempfile'

require 'spec_helper'
require_relative '../../lib/subtitler/semantic_diff'

RSpec.describe Subtitler::Subtitle::SemanticDiff do
  let(:entry) { Subtitler::Subtitle::Entry }
  let(:word) { Subtitler::Subtitle::Word }

  def compare(before, after, **options)
    described_class.compare(before, after, **options)
  end

  def srt(text)
    Subtitler::Subtitle.from_srt(text)
  end

  def vtt(text)
    Subtitler::Subtitle.from_vtt(text)
  end

  it 'ignores SRT identifier, line-ending, and final-newline formatting changes' do
    before = srt("1\n00:00:00,000 --> 00:00:01,000\nHello\n\n2\n00:00:01,000 --> 00:00:02,000\nWorld\n")
    after  = srt("101\r\n00:00:00.000 --> 00:00:01.000\r\nHello\r\n\r\n202\r\n00:00:01.000 --> 00:00:02.000\r\nWorld")

    result = compare(before, after)

    expect(result.fetch(:summary)).to include(
      identical: true,
      before_cue_count: 2,
      after_cue_count: 2,
      matched_cue_count: 2,
      difference_count: 0,
    )
    expect(result.fetch(:details)).to be_empty
  end

  it 'reports normalized cue text changes' do
    result = compare(
      srt("1\n00:00:00,000 --> 00:00:01,000\nHello   world\n"),
      srt("1\n00:00:00,000 --> 00:00:01,000\nHello there\n"),
    )

    expect(result.fetch(:details)).to include(
      a_hash_including(
        type: 'text_changed',
        before_text: 'Hello world',
        after_text: 'Hello there',
      ),
    )
  end

  it 'ignores timing changes within tolerance and reports changes outside it' do
    before = srt("1\n00:00:00,000 --> 00:00:01,000\nHello\n")
    within = srt("1\n00:00:00,009 --> 00:00:01,009\nHello\n")
    outside = srt("1\n00:00:00,020 --> 00:00:01,020\nHello\n")

    expect(compare(before, within).fetch(:summary)).to include(identical: true, max_start_delta: 0.009)
    expect(compare(before, outside).fetch(:details)).to include(
      a_hash_including(type: 'timing_changed', start_delta: 0.02, finish_delta: 0.02),
    )
  end

  it 'reports word timing changes without treating the highlight marker as cue text' do
    before = vtt("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nOne <00:00:01.000>two\n")
    after  = vtt("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nOne <00:00:01.200>two\n")

    result = compare(before, after)

    expect(result.fetch(:summary)).to include(
      identical: false,
      max_word_start_delta: 0.2,
      max_word_finish_delta: 0.2,
    )
    expect(result.fetch(:details)).to include(a_hash_including(type: 'word_timing_changed'))
    expect(result.fetch(:details)).not_to include(a_hash_including(type: 'text_changed'))
  end

  it 'reports speaker changes from the typed subtitle model' do
    before = Subtitler::Subtitle.new(entries: [entry.new(start: 0, finish: 1, text: 'Hello', speaker_id: 1)])
    after  = Subtitler::Subtitle.new(entries: [entry.new(start: 0, finish: 1, text: 'Hello', speaker_id: 2)])

    expect(compare(before, after).fetch(:details)).to include(
      a_hash_including(
        type: 'speaker_changed',
        before_speaker_id: 1,
        after_speaker_id: 2,
      ),
    )
  end

  it 'aligns inserted cues by timing and does not cascade text changes' do
    before = Subtitler::Subtitle.new(entries: [
      entry.new(start: 0, finish: 1, text: 'A'),
      entry.new(start: 1, finish: 2, text: 'B'),
      entry.new(start: 2, finish: 3, text: 'C'),
    ])
    after = Subtitler::Subtitle.new(entries: [
      entry.new(start: 0, finish: 0.4, text: 'Inserted'),
      entry.new(start: 0.4, finish: 1.4, text: 'A'),
      entry.new(start: 1.4, finish: 2.4, text: 'B'),
      entry.new(start: 2.4, finish: 3.4, text: 'C'),
    ])

    result = compare(before, after, time_tolerance: 0.01)
    summary = result.fetch(:summary)

    expect(summary).to include(
      matched_cue_count: 3,
      unmatched_before_cue_count: 0,
      unmatched_after_cue_count: 1,
    )
    expect(result.fetch(:details)).to include(a_hash_including(type: 'cue_added', after_text: 'Inserted'))
    expect(result.fetch(:details)).not_to include(a_hash_including(type: 'text_changed'))
  end

  it 'reports VTT identifiers, settings, and presentation metadata changes' do
    before = vtt(<<~VTT)
      WEBVTT

      cue-one
      00:00:00.000 --> 00:00:02.000 align:start position:50%
      <b>Hello</b>
    VTT
    after = vtt(<<~VTT)
      WEBVTT

      cue-two
      00:00:00.000 --> 00:00:02.000 align:end position:50%
      <i>Hello</i>
    VTT

    result = compare(before, after)
    types = result.fetch(:summary).fetch(:differences_by_type).keys

    expect(types).to include(
      'cue_identifier_changed',
      'cue_settings_changed',
      'cue_presentation_changed',
    )
    expect(result.fetch(:details)).not_to include(a_hash_including(type: 'text_changed'))
  end

  it 'returns a deterministic JSON-compatible bounded result shape' do
    before = srt("1\n00:00:00,000 --> 00:00:01,000\nBefore\n")
    after = srt("1\n00:00:00,000 --> 00:00:01,000\nAfter\n")

    result = compare(before, after, max_details: 0)
    parsed = JSON.parse(JSON.generate(result))

    expect(result.keys).to eq(%i[summary details details_truncated])
    expect(parsed.keys).to eq(%w[summary details details_truncated])
    expect(result.fetch(:details)).to be_empty
    expect(result.fetch(:details_truncated)).to be(true)
    expect(JSON.generate(result)).not_to include('object_id')
  end

  it 'supports the CLI JSON report and fail-on-difference exit status' do
    Tempfile.create(['before', '.srt']) do |before_file|
      Tempfile.create(['after', '.srt']) do |after_file|
        before_file.write("\uFEFF1\n00:00:00,000 --> 00:00:01,000\nBefore\n")
        before_file.flush
        after_file.write("1\n00:00:00,000 --> 00:00:01,000\nAfter\n")
        after_file.flush
        cli = File.expand_path('../../bin/subtitle_semantic_diff', __dir__)
        stdout, stderr, status = Open3.capture3(
          RbConfig.ruby, cli, before_file.path, after_file.path, '--json', '--fail-on-difference'
        )

        expect(stderr).to be_empty
        expect(status.exitstatus).to eq(1)
        expect(JSON.parse(stdout).dig('comparison', 'summary', 'identical')).to be(false)
      end
    end
  end

  it 'accepts explicit word models with text and timing differences' do
    before = Subtitler::Subtitle.new(entries: [entry.new(
      start: 0, finish: 2, text: 'One two', words: [
        word.new(text: 'One', start: 0, finish: 1),
        word.new(text: 'two', start: 1, finish: 2),
      ]
    )])
    after = Subtitler::Subtitle.new(entries: [entry.new(
      start: 0, finish: 2, text: 'One three', words: [
        word.new(text: 'One', start: 0, finish: 1.2),
        word.new(text: 'three', start: 1.2, finish: 2),
      ]
    )])

    types = compare(before, after).fetch(:summary).fetch(:differences_by_type).keys

    expect(types).to include('word_text_changed', 'word_timing_changed')
  end
end
