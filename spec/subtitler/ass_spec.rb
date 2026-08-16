require 'spec_helper'

RSpec.describe Subtitler::Ass do
  let(:timed_vtt) do
    <<~VTT
      WEBVTT

      00:00:00.000 --> 00:00:02.000
      One <00:00:01.000>two
    VTT
  end

  it 'renders plain cues as one dialogue without inline timestamps' do
    dialogue = described_class.from_vtt(timed_vtt, mode: :plain).lines.grep(/^Dialogue:/)

    expect(dialogue).to eq([
      "Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,One two\n",
    ])
  end

  it 'renders instagram cues as one precisely bounded event per highlighted word' do
    dialogues = described_class.from_vtt(timed_vtt, mode: :instagram).lines.grep(/^Dialogue:/)

    expect(dialogues).to eq([
      "Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,{\\1c&Hffffff&}One{\\1c&HC0C0C0&} two\n",
      "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,One {\\1c&Hffffff&}two{\\1c&HC0C0C0&}\n",
    ])
  end

  it 'renders karaoke cues as one event with rounded centisecond durations' do
    dialogue = described_class.from_vtt(timed_vtt, mode: :karaoke).lines.grep(/^Dialogue:/)

    expect(dialogue).to eq([
      "Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,{\\k100}One {\\k100}two\n",
    ])
  end

  it 'applies every preset style and its corresponding instagram highlight tags' do
    expectations = {
      'default' => {
        style: 'Roboto Medium,20,&H00ffffff,&H0000ffff,&HFF000000,&H80000000,0,0,0,0,100,100,0,0,4,4,0,2,10,10,32,1',
        highlight: '{\\1c&Hffffff&}One{\\1c&HC0C0C0&}',
      },
      'hlword' => {
        style: 'Roboto Medium,20,&H00ffffff,&H0000ffff,&HFF000000,&H80000000,0,0,0,0,100,100,0,0,4,4,0,2,10,10,32,1',
        highlight: '{\\1c&H00ffff&}One{\\1c&Hffffff&}',
      },
      'nobg' => {
        style: 'Roboto Medium,20,&H00ffffff,&H0000ffff,&H80000000,&H00000000,0,0,0,0,100,100,0,0,1,0,2,2,10,10,32,1',
        highlight: '{\\bord2\\shad0\\be1\\3c&H000000&\\4c&H00ffff&}One{\\r}{\\1c&Hffffff&}',
      },
    }

    expectations.each do |preset, expected|
      ass = described_class.from_vtt(timed_vtt, preset: preset)

      expect(ass).to include("Style: Default,#{expected[:style]}")
      expect(ass).to include(expected[:highlight])
    end
  end

  it 'falls back to the default preset for an unknown name' do
    fallback = described_class.from_vtt(timed_vtt, preset: 'missing')
    default = described_class.from_vtt(timed_vtt, preset: 'default')

    expect(fallback).to eq(default)
  end

  it 'scales only the preset font size for portrait output' do
    portrait = described_class.from_vtt(timed_vtt, portrait: true)

    expect(portrait).to include('Style: Default,Roboto Medium,12,')
    expect(portrait).to include(',2,10,10,32,1')
  end

  it 'renders a cue without inline word timings as one dialogue' do
    vtt = <<~VTT
      WEBVTT

      cue identifier
      00:00:03.000 --> 00:00:04.500 position:50%
      Whole cue
      on two lines
    VTT

    dialogues = described_class.from_vtt(vtt).lines.grep(/^Dialogue:/)

    expect(dialogues).to eq([
      "Dialogue: 0,0:00:03.00,0:00:04.50,Default,,0,0,0,,Whole cue\\Non two lines\n",
    ])
  end

  it 'drops blocks that have no cue timing line' do
    vtt = "WEBVTT\n\nNOTE this block is untimed\nIgnored text\n"

    expect(described_class.from_vtt(vtt).lines.grep(/^Dialogue:/)).to be_empty
  end

  it 'writes the standard dialogue fields and preserves commas in the text field' do
    vtt = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello, world\n"
    dialogue = described_class.from_vtt(vtt).lines.grep(/^Dialogue:/).first.chomp

    expect(dialogue.split(',', 10)).to eq([
      'Dialogue: 0', '0:00:00.00', '0:00:01.00', 'Default', '', '0', '0', '0', '', 'Hello, world',
    ])
  end

  it 'decodes HTML entities and preserves current ASS override syntax' do
    vtt = <<~'VTT'
      WEBVTT

      00:00:00.000 --> 00:00:01.000
      Tom &amp; Jerry {\i1}italic{\i0}
    VTT

    dialogue = described_class.from_vtt(vtt).lines.grep(/^Dialogue:/).first

    expect(dialogue).to end_with("Tom & Jerry {\\i1}italic{\\i0}\n")
  end

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

  describe Subtitler::Ass::Document do
    it 'represents every V4+ style field and all event fields' do
      expect(Subtitler::Ass::Style::DEFAULTS.keys).to eq(Subtitler::Ass::STYLE_FIELDS)

      event = Subtitler::Ass::Event.new(
        layer: 2, start: 1.25, finish: 2.5, style: 'Caption', name: 'speaker',
        margin_l: 1, margin_r: 2, margin_v: 3, effect: 'scroll', text: 'Hello, world'
      )

      expect(event.serialize).to eq(
        '2,0:00:01.25,0:00:02.50,Caption,speaker,1,2,3,scroll,Hello, world'
      )
    end

    it 'serializes represented extension fields and unknown sections' do
      style_fields = Subtitler::Ass::STYLE_FIELDS + ['Blur']
      event_fields = Subtitler::Ass::EVENT_FIELDS + ['Source']
      style = Subtitler::Ass::Style.new(fontname: 'Inter', extensions: {'Blur' => 3})
      event = Subtitler::Ass::Event.new(
        start: 0, finish: 1, text: 'Extended', extensions: {'Source' => 'model'}
      )
      document = described_class.new(
        script_info: Subtitler::Ass::SCRIPT_INFO.merge('YCbCr Matrix' => 'TV.709'),
        styles: [style], events: [event], style_fields: style_fields, event_fields: event_fields,
        sections: {'Aegisub Project Garbage' => ['Last Style Storage: Default']}
      )

      expect(document.to_s).to include(
        "YCbCr Matrix: TV.709\n",
        "Format: #{style_fields.join(',')}\n",
        'Style: Default,Inter,20,',
        "#{event_fields.join(', ')}\n",
        'Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,Extended,model',
        "[Aegisub Project Garbage]\nLast Style Storage: Default\n"
      )
    end
  end

  it 'renders directly from typed entries without interpreting marker-like text' do
    subtitle = Subtitler::Subtitle.new(entries: [
      Subtitler::Subtitle::Entry.new(
        start: 0, finish: 1, text: 'Literal <00:00:00.500> marker {\i1}kept{\i0}'
      ),
    ])

    dialogue = subtitle.to_ass(mode: :plain).lines.grep(/^Dialogue:/).first

    expect(dialogue).to end_with("Literal <00:00:00.500> marker {\\i1}kept{\\i0}\n")
  end
end
