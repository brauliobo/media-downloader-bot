require 'spec_helper'
require_relative '../../lib/diarizer/tiny_diarize'

RSpec.describe Diarizer::TinyDiarize do
  let(:dir) { Dir.mktmpdir('tinydiarize-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }
  let(:wav) { File.join(dir, 'input.wav') }

  before do
    File.write(input, 'video')
    File.write(wav, 'wav')
    allow(Zipper).to receive(:audio_to_wav).with(input).and_return(wav)
  end

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def response_with_turns
    body = JSON.dump(
      language: 'English',
      segments: [
        { start: 0.0, end: 1.0, text: 'One.', speaker_turn_next: true },
        { start: 1.0, end: 2.0, text: 'Two.', speaker_turn_next: true },
        { start: 2.0, end: 3.0, text: 'Still two.', speaker_turn_next: true },
        { start: 3.0, end: 4.0, text: 'Four.', speaker_turn_next: false },
      ]
    )
    double(code: '200', body: body)
  end

  it 'uses a unique ID for each uninterrupted turn by default' do
    response = response_with_turns

    expect(Utils::HTTP).to receive(:post) do |url, params|
      expect(url).to eq('http://127.0.0.1:8081/inference')
      expect(params).to include(language: 'en', response_format: 'verbose_json', tinydiarize: 'true')
      response
    end

    output = described_class.diarize(input)

    expect(output.segments.map(&:speaker_id)).to eq([0, 1, 2, 3])
    expect(File.exist?(wav)).to be(false)
  end

  it 'reuses identities when the number of speakers is known' do
    allow(Utils::HTTP).to receive(:post).and_return(response_with_turns)

    output = described_class.diarize(input, speakers: 2)

    expect(output.segments.map(&:speaker_id)).to eq([0, 1, 0, 1])
    expect(File.exist?(wav)).to be(false)
  end

  it 'rejects an unpatched whisper.cpp server response' do
    response = double(
      code: '200',
      body: JSON.dump(segments: [{ start: 0.0, end: 1.0, text: 'No turn metadata.' }])
    )
    allow(Utils::HTTP).to receive(:post).and_return(response)

    expect { described_class.diarize(input) }.to raise_error(/did not return speaker_turn_next/)
  end
end
