require 'spec_helper'
require_relative '../../lib/dubbing/voice_reference'

RSpec.describe Dubbing::VoiceReference do
  let(:dir) { Dir.mktmpdir('voice-ref-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }

  before { File.write(input, 'video') }
  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def sentence(start, finish, source_text:, source_words: [], speaker_id: 0)
    SymMash.new(start: start, end: finish, source_text: source_text, source_words: source_words, speaker_id: speaker_id)
  end

  def segment(start, finish, speaker_id: 0)
    SymMash.new(start: start, end: finish, speaker_id: speaker_id)
  end

  def ok_status
    instance_double(Process::Status, success?: true)
  end

  before do
    allow(described_class).to receive(:extract_span) do |_input, selection, output_dir, idx|
      File.join(output_dir, format('speaker-%04d.wav', idx)).tap do |path|
        File.write(path, "#{selection.start}:#{selection.duration}")
      end
    end
    allow(Zipper).to receive(:concat_audio) do |clips, output|
      File.write(output, clips.join("\n"))
      output
    end
  end

  it 'builds an independent reference for every detected speaker turn' do
    segments = [
      segment(0, 2, speaker_id: 0),
      segment(3, 6, speaker_id: 1),
      segment(7, 9, speaker_id: 0),
    ]
    sentences = [
      sentence(0, 2, source_text: 'Speaker zero.'),
      sentence(3, 6, source_text: 'Speaker one.', speaker_id: 1),
      sentence(7, 9, source_text: 'Speaker zero again.'),
    ]

    references = described_class.extract_by_speaker(input, segments, sentences: sentences, dir: dir)

    expect(references.keys).to eq([0, 1])
    expect(references.fetch(0).text).to eq('Speaker zero. Speaker zero again.')
    expect(references.fetch(1).text).to eq('Speaker one.')
    expect(references.values.map { |reference| File.dirname(reference.path) }.uniq.size).to eq(2)
  end

  it 'supports backend-native string speaker labels' do
    references = described_class.extract_by_speaker(
      input,
      [segment(0, 3, speaker_id: 'SPEAKER_00')],
      sentences: [sentence(0, 3, source_text: 'Speaker zero.', speaker_id: 'SPEAKER_00')],
      dir: dir
    )

    expect(references.fetch('SPEAKER_00').text).to eq('Speaker zero.')
  end

  it 'provides its own TTS voice-cloning options' do
    reference = described_class::Reference.new(path: '/tmp/speaker.wav', text: 'Reference text.')

    expect(reference.tts_options).to eq(speaker_wav: '/tmp/speaker.wav', ref_text: 'Reference text.')
  end

  it 'combines complete reference sentences up to the cap' do
    segments = [segment(0, 1, speaker_id: 0), segment(2, 6, speaker_id: 0)]
    sentences = [
      sentence(0, 1, source_text: 'Thank you.'),
      sentence(2, 6, source_text: 'I worked at an accounting firm.', speaker_id: 0),
    ]

    reference = described_class.extract_by_speaker(input, segments, sentences: sentences, dir: dir).fetch(0)

    expect(reference.text).to eq('Thank you. I worked at an accounting firm.')
  end

  it 'skips a sentence that would overflow so later complete sentences can fit' do
    segments = [segment(0, 6), segment(7, 12), segment(13, 17)]
    sentences = [
      sentence(0, 6, source_text: 'First sentence.'),
      sentence(7, 12, source_text: 'Too large to fit.'),
      sentence(13, 17, source_text: 'Final sentence.'),
    ]

    reference = described_class.extract_by_speaker(input, segments, sentences: sentences, dir: dir).fetch(0)

    expect(reference.text).to eq('First sentence. Final sentence.')
    expect(File.readlines(reference.path).size).to eq(2)
  end

  it 'repeats only the same turn when a reference is shorter than three seconds' do
    references = described_class.extract_by_speaker(
      input,
      [segment(4, 4.5)],
      sentences: [sentence(4, 4.5, source_text: 'Brief.')],
      dir: dir
    )

    reference = references.fetch(0)
    expect(reference.text).to eq(Array.new(6, 'Brief.').join(' '))
    expect(File.readlines(reference.path).size).to eq(6)
  end

  it 'uses only complete segments within the ten-second reference cap' do
    segments = [
      segment(0, 6),
      segment(6, 11),
    ]
    sentences = [
      sentence(0, 6, source_text: 'First.'),
      sentence(6, 11, source_text: 'Would exceed cap.'),
    ]

    reference = described_class.extract_by_speaker(input, segments, sentences: sentences, dir: dir).fetch(0)

    expect(reference.text).to eq('First.')
    expect(File.readlines(reference.path).size).to eq(1)
  end

  it 'uses complete sentence boundaries instead of fragmented speaker intervals' do
    sentences = [
      sentence(0.0, 3.5, source_text: 'Hello there.', speaker_id: 'A'),
      sentence(3.5, 6.5, source_text: 'Goodbye.', speaker_id: 'B'),
    ]
    segments = [segment(0.5, 1.5, speaker_id: 'A'), segment(4.0, 5.0, speaker_id: 'B')]

    references = described_class.extract_by_speaker(input, segments, sentences: sentences, dir: dir)

    expect(references.fetch('A').text).to eq('Hello there.')
    expect(references.fetch('B').text).to eq('Goodbye.')
  end

  it 'cleans source noise before using a speaker interval as an OmniVoice reference' do
    allow(described_class).to receive(:extract_span).and_call_original
    selection = described_class::Selection.new(start: 1.0, duration: 4.0, text: 'Clean phrase.')
    expect(Sh).to receive(:run) do |command|
      command = command.join(' ')
      expect(command).to include('afftdn', 'highpass', 'lowpass', 'silenceremove', 'loudnorm', 'apad')
      output = File.join(dir, 'speaker-0001.wav')
      File.write(output, 'clean reference')
      ['', '', ok_status]
    end

    output = described_class.extract_span(input, selection, dir, 1)

    expect(output).to eq(File.join(dir, 'speaker-0001.wav'))
  end
end
