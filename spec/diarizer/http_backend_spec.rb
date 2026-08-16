require 'spec_helper'
require_relative '../../lib/diarizer/http_backend'

RSpec.describe Diarizer::HTTPBackend do
  let(:dir) { Dir.mktmpdir('diarizer-http-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }
  let(:wav) { File.join(dir, 'input.wav') }
  let(:api) { URI.parse('http://127.0.0.1:9000') }

  before do
    File.write(input, 'video')
    File.write(wav, 'wav')
    allow(Zipper).to receive(:audio_to_wav)
      .with(input, sample_rate: 16_000, channels: 1)
      .and_return(wav)
  end

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  it 'posts normalized audio and an explicit speaker count' do
    response = double(
      code: '200',
      body: JSON.dump(segments: [{start: 0.1, end: 1.2, speaker_id: 'SPEAKER_00'}])
    )
    expect(Utils::HTTP).to receive(:post) do |url, params|
      expect(url).to eq('http://127.0.0.1:9000/v1/diarize')
      expect(params[:file]).to be_a(File)
      expect(params[:speakers]).to eq('2')
      response
    end

    output = described_class.diarize(api, input, speakers: 2)

    expect(output).to be_a(Diarizer::Result)
    expect(output.segments.first).to have_attributes(
      start: 0.1, finish: 1.2, speaker_id: 'SPEAKER_00'
    )
    expect(File.exist?(wav)).to be(false)
  end

  it 'rejects malformed service output' do
    response = double(code: '200', body: JSON.dump(segments: [{start: 0.1, end: 1.2}]))
    allow(Utils::HTTP).to receive(:post).and_return(response)

    expect { described_class.diarize(api, input) }.to raise_error(/malformed speaker segments/)
  end

  it 'rejects invalid time ranges' do
    response = double(
      code: '200',
      body: JSON.dump(segments: [{start: 1.2, end: 0.1, speaker_id: 'SPEAKER_00'}])
    )
    allow(Utils::HTTP).to receive(:post).and_return(response)

    expect { described_class.diarize(api, input) }.to raise_error(/malformed speaker segments/)
  end
end
