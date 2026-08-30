require 'spec_helper'
require_relative '../../lib/voice_activity/silero'

RSpec.describe VoiceActivity::Silero do
  it 'uses the Silero VAD service endpoint' do
    expect(VoiceActivity::HTTPBackend).to receive(:detect)
      .with(URI.parse('http://127.0.0.1:8089'), 'input.mp4')
      .and_return(:output)

    expect(described_class.detect('input.mp4')).to eq(:output)
  end
end
