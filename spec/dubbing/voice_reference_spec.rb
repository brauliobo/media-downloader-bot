require 'spec_helper'
require_relative '../../lib/dubbing/voice_reference'

RSpec.describe Dubbing::VoiceReference do
  let(:dir) { Dir.mktmpdir('voice-ref-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }

  before { File.write(input, 'video') }
  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def sentence(start, finish, source_text:, source_words: [], speaker_id: 0)
    Subtitler::Subtitle::Entry.new(
      start: start, finish: finish, text: source_text, source_text: source_text,
      source_words: source_words, speaker_id: speaker_id
    )
  end

  def segment(start, finish, speaker_id: 0)
    Diarizer::Segment.new(start: start, finish: finish, speaker_id: speaker_id)
  end

  def transcript(*texts)
    entries = texts.each_with_index.map do |text, index|
      Subtitler::Subtitle::Entry.new(start: index, finish: index + 1, text: text)
    end
    Subtitler::Subtitle.new(entries: entries)
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

  it 'rejects subtitle hashes' do
    expect do
      described_class.extract_by_speaker(input, [segment(0, 1)], sentences: [{text: 'Hello.'}], dir: dir)
    end.to raise_error(TypeError, /Subtitle::Entry/)
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

  it 'ignores diarized speakers without matching transcript sentences' do
    references = described_class.extract_by_speaker(
      input,
      [
        segment(0, 1, speaker_id: 'SPEAKER_00'),
        segment(2, 6, speaker_id: 'SPEAKER_01'),
      ],
      sentences: [sentence(2, 6, source_text: 'Speaker one.', speaker_id: 'SPEAKER_01')],
      dir: dir
    )

    expect(references.keys).to eq(['SPEAKER_01'])
  end

  it 'provides its own TTS voice-cloning options' do
    reference = described_class::Reference.new(path: '/tmp/speaker.wav', text: 'Reference text.')

    expect(reference.tts_options).to eq(speaker_wav: '/tmp/speaker.wav', ref_text: 'Reference text.')
  end

  it 'uses the extracted audio transcript when one is provided' do
    transcriber = instance_double('VoiceReference::Transcriber', call: transcript('Observed reference.'))

    reference = described_class.extract_by_speaker(
      input,
      [segment(0, 3)],
      sentences: [sentence(0, 3, source_text: 'Hallucinated reference.')],
      dir: dir,
      transcriber: transcriber
    ).fetch(0)

    expect(reference.text).to eq('Observed reference.')
  end

  it 'skips a speaker whose extracted audio has no transcribed speech' do
    transcriber = instance_double('VoiceReference::Transcriber', call: transcript('  '))

    references = described_class.extract_by_speaker(
      input,
      [segment(0, 3, speaker_id: 'SPEAKER_01')],
      sentences: [sentence(0, 3, source_text: 'Hallucinated speech.', speaker_id: 'SPEAKER_01')],
      dir: dir,
      transcriber: transcriber
    )

    expect(references).to be_empty
  end

  it 'uses bounded diarization turns when assigned transcript sentences are too long' do
    transcriber = instance_double('VoiceReference::Transcriber')
    allow(transcriber).to receive(:call).and_return(transcript('Observed speaker turn.'))

    reference = described_class.extract_by_speaker(
      input,
      [segment(10, 22, speaker_id: 'SPEAKER_01')],
      sentences: [sentence(0, 20, source_text: 'A transcript span that is too long.', speaker_id: 'SPEAKER_01')],
      dir: dir,
      transcriber: transcriber
    ).fetch('SPEAKER_01')

    clip = File.join(dir, 'speaker-0000', 'speaker-0001.wav')
    expect(File.read(clip)).to eq('10.0:8.0')
    expect(reference.text).to eq('Observed speaker turn.')
    expect(transcriber).to have_received(:call).with(reference.path)
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
    segments = [segment(0, 4), segment(7, 12), segment(13, 17)]
    sentences = [
      sentence(0, 4, source_text: 'First sentence.'),
      sentence(7, 12, source_text: 'Too large to fit.'),
      sentence(13, 17, source_text: 'Final sentence.'),
    ]

    reference = described_class.extract_by_speaker(input, segments, sentences: sentences, dir: dir).fetch(0)

    expect(reference.text).to eq('First sentence. Final sentence.')
    expect(File.readlines(reference.path).size).to eq(2)
  end

  it 'keeps a short reference instead of repeating the same turn' do
    references = described_class.extract_by_speaker(
      input,
      [segment(4, 4.5)],
      sentences: [sentence(4, 4.5, source_text: 'Brief.')],
      dir: dir
    )

    reference = references.fetch(0)
    expect(reference.text).to eq('Brief.')
    expect(File.readlines(reference.path).size).to eq(1)
  end

  it 'uses only complete segments within the eight-second reference cap' do
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

  it 'keeps raw source audio by default for an OmniVoice reference' do
    allow(described_class).to receive(:extract_span).and_call_original
    selection = described_class::Selection.new(start: 1.0, duration: 4.0, text: 'Clean phrase.')
    expect(Sh).to receive(:run) do |command|
      command = command.join(' ')
      expect(command).not_to include('-af', 'afftdn', 'highpass', 'loudnorm', 'apad')
      output = File.join(dir, 'speaker-0001.wav')
      File.write(output, 'clean reference')
      ['', '', ok_status]
    end

    output = described_class.extract_span(input, selection, dir, 1)

    expect(output).to eq(File.join(dir, 'speaker-0001.wav'))
  end

  it 'allows the full quality filter and reference padding as explicit options' do
    allow(described_class).to receive(:extract_span).and_call_original
    selection = described_class::Selection.new(start: 1.0, duration: 4.0, text: 'Quality phrase.')
    expect(Sh).to receive(:run) do |command|
      command = command.join(' ')
      expect(command).to include('lowpass', 'silenceremove', 'loudnorm', 'apad=pad_dur=0.15')
      output = File.join(dir, 'speaker-0001.wav')
      File.write(output, 'quality reference')
      ['', '', ok_status]
    end

    output = described_class.extract_span(
      input, selection, dir, 1, filter: :quality, pad_duration: described_class::REFERENCE_GAP
    )

    expect(output).to eq(File.join(dir, 'speaker-0001.wav'))
  end
end
