require 'rails_helper'

RSpec.describe VoiceActivity do
  let(:dir) { Dir.mktmpdir('voice-activity-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def ranges(*pairs)
    Utils::TimeRanges.new(
      pairs.map { |start, finish| Utils::TimeRanges::Interval.new(start: start, finish: finish) },
      option: :vad
    )
  end

  it 'uses Silero as the default backend' do
    expect(described_class::BACKEND).to eq(described_class::Silero)
  end

  it 'delegates detection to the selected backend' do
    detected = ranges([0.1, 1.2])
    expect(described_class::BACKEND).to receive(:detect).with(input).and_return(detected)

    expect(described_class.detect(input)).to eq(detected)
  end

  it 'extracts concatenated speech ranges and removes them after the caller finishes' do
    speech_path = nil
    detected = ranges([1.0, 3.0])
    allow(described_class::BACKEND).to receive(:detect).with(input).and_return(detected)
    ffmpeg = instance_double(FFmpeg)
    allow(FFmpeg).to receive(:new).and_return(ffmpeg)
    expect(ffmpeg).to receive(:extract_speech_ranges) do |arguments|
      expect(arguments[:input]).to eq(input)
      expect(arguments[:ranges]).to eq(detected)
      File.write(arguments[:output], 'speech')
      arguments[:output]
    end

    described_class.with_speech(input) do |speech, found|
      speech_path = speech
      expect(File.read(speech)).to eq('speech')
      expect(found).to eq(detected)
    end

    expect(speech_path).to be_a(String)
    expect(File.exist?(speech_path)).to be(false)
  end

  it 'yields no speech path when VAD finds no ranges' do
    allow(described_class::BACKEND).to receive(:detect).with(input).and_return(ranges)
    expect(FFmpeg).not_to receive(:new)

    described_class.with_speech(input) do |speech, detected|
      expect(speech).to be_nil
      expect(detected).to be_empty
    end
  end

  it 'maps concatenated whisper times back onto the source timeline' do
    subtitle = Subtitler::Subtitle.new(
      language: 'en',
      text: 'Hi there.',
      entries: [Subtitler::Subtitle::Entry.new(
        start: 0.5, finish: 2.5, text: 'Hi there.',
        words: [
          Subtitler::Subtitle::Word.new(text: 'Hi', start: 0.5, finish: 1.0),
          Subtitler::Subtitle::Word.new(text: 'there.', start: 2.2, finish: 2.8),
        ]
      )]
    )

    described_class.restore_timing!(subtitle, ranges([10.0, 12.0], [20.0, 21.0]))

    expect(subtitle.entries.first).to have_attributes(start: 10.5, finish: 20.5)
    expect(subtitle.entries.first.words.map { |word| [word.start, word.finish] }).to eq([
      [10.5, 11.0], [20.2, 20.8],
    ])
  end
end
