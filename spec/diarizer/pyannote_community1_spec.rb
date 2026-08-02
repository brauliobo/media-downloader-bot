require 'spec_helper'
require_relative '../../lib/diarizer/pyannote_community1'

RSpec.describe Diarizer::PyannoteCommunity1 do
  it 'uses the pyannote service endpoint' do
    expect(Diarizer::HTTPBackend).to receive(:diarize)
      .with(URI.parse('http://127.0.0.1:8082'), 'input.mp4', speakers: 3)
      .and_return(:output)

    expect(described_class.diarize('input.mp4', speakers: 3)).to eq(:output)
  end
end
