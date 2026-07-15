require 'spec_helper'

RSpec.describe TTS::Chatterbox do
  it 'uses the stable default temperature' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('CHATTERBOX_TEMPERATURE').and_return(nil)
    expect(described_class).to receive(:http_synthesize).with(
      text:        'Filho: não há qualquer mal em nossa Doutrina.',
      lang:        'pt',
      out_path:    '/tmp/filho.wav',
      speaker_wav: nil,
      temperature: 0.3,
    )

    described_class.synthesize(
      text:     'Filho: não há qualquer mal em nossa Doutrina.',
      lang:     'pt',
      out_path: '/tmp/filho.wav',
    )
  end
end
