require 'rails_helper'

RSpec.describe VoiceActivity::HTTPBackend do
  let(:dir) { Dir.mktmpdir('voice-activity-http-spec-') }
  let(:input) { File.join(dir, 'input.mp4') }
  let(:wav) { File.join(dir, 'input.wav') }
  let(:api) { URI.parse('http://127.0.0.1:9000') }

  before do
    File.write(input, 'video')
    File.write(wav, 'wav')
    allow(Zipper::AudioOps).to receive(:to_wav)
      .with(input, sample_rate: 16_000, channels: 1)
      .and_return(wav)
  end

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  it 'posts normalized audio and returns speech ranges' do
    response = double(code: '200', body: JSON.dump(segments: [{start: 0.1, end: 1.2}, {start: 3.0, end: 4.5}]))
    expect(Utils::HTTP).to receive(:post) do |url, params|
      expect(url).to eq('http://127.0.0.1:9000/v1/vad')
      expect(params[:file]).to be_a(File)
      response
    end

    output = described_class.detect(api, input)

    expect(output.intervals).to eq([
      Utils::TimeRanges::Interval.new(start: 0.1, finish: 1.2),
      Utils::TimeRanges::Interval.new(start: 3.0, finish: 4.5),
    ])
    expect(File.exist?(wav)).to be(false)
  end

  it 'rejects malformed service output' do
    allow(Utils::HTTP).to receive(:post)
      .and_return(double(code: '200', body: JSON.dump(segments: [{start: 0.1}])))

    expect { described_class.detect(api, input) }
      .to raise_error(ArgumentError, 'voice activity detection returned malformed speech ranges')
  end

  it 'rejects invalid time ranges' do
    allow(Utils::HTTP).to receive(:post)
      .and_return(double(code: '200', body: JSON.dump(segments: [{start: 1.2, end: 0.1}])))

    expect { described_class.detect(api, input) }
      .to raise_error(ArgumentError, 'voice activity detection returned malformed speech ranges')
  end
end
