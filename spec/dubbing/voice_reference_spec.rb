require 'spec_helper'
require_relative '../../lib/dubbing/voice_reference'

RSpec.describe Dubbing::VoiceReference do
  let(:dir) { Dir.mktmpdir('voice-ref-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }

  before { File.write(input, 'video') }
  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def sentence(start, finish)
    SymMash.new(start: start, end: finish)
  end

  def ok_status
    instance_double(Process::Status, success?: true)
  end

  it 'selects only sentence spans up to the reference duration cap' do
    spans = described_class.selected_spans(
      [sentence(0, 8), sentence(10, 25), sentence(30, 40)],
      20.0
    )

    expect(spans.map(&:duration)).to eq([8.0, 12.0])
    expect(spans.sum(&:duration)).to eq(20.0)
  end

  it 'extracts short source spans and never passes the whole video as the speaker wav' do
    commands = []
    allow(Sh).to receive(:run) do |cmd|
      commands << cmd
      out = cmd.split.last
      File.write(out, 'clip')
      ['', '', ok_status]
    end
    concat_inputs = nil
    allow(Zipper).to receive(:concat_audio) do |clips, out|
      concat_inputs = clips
      File.write(out, clips.join("\n"))
      out
    end

    output = described_class.extract(input, [sentence(2, 5), sentence(10, 14)], dir: dir, max_duration: 20)

    expect(output).to end_with('speaker.wav')
    expect(commands).to all(include('-ss '))
    expect(commands).to all(include('-t '))
    expect(concat_inputs).to all(match(/speaker-\d+\.wav\z/))
    expect(concat_inputs).not_to include(input)
  end
end
