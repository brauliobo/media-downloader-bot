require 'spec_helper'
require_relative '../../lib/diarizer/sherpa_onnx'

RSpec.describe Diarizer::SherpaOnnx do
  it 'uses the sherpa-onnx service endpoint' do
    expect(Diarizer::HTTPBackend).to receive(:diarize)
      .with(URI.parse('http://127.0.0.1:8083'), 'input.mp4', speakers: nil)
      .and_return(:output)

    expect(described_class.diarize('input.mp4')).to eq(:output)
  end
end
