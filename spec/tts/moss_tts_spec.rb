require 'spec_helper'

RSpec.describe TTS::MossTTS do
  it 'sends language, temperature, and reference audio to the HTTP server' do
    Dir.mktmpdir('moss-tts-spec-') do |dir|
      out_path = File.join(dir, 'out.wav')
      reference_path = File.join(dir, 'reference.wav')
      File.binwrite(reference_path, 'reference')
      agent = double
      response = double(code: '200', body: 'wav')
      captured_form = nil
      captured_audio = nil

      allow(Utils::HTTP).to receive(:client).and_return(agent)
      allow(agent).to receive(:post) do |_url, form|
        captured_form = form
        captured_audio = form['audio'].read
        response
      end

      described_class.synthesize(
        text:        'Uma frase em português.',
        lang:        'pt',
        out_path:    out_path,
        speaker_wav: reference_path,
        temperature: 0.4
      )

      expect(captured_form['language']).to eq('pt')
      expect(captured_form['temperature']).to eq('0.4')
      expect(captured_audio).to eq('reference')
      expect(File.binread(out_path)).to eq('wav')
    end
  end

  it 'reports the model output sample rate' do
    expect(described_class.output_sample_rate).to eq(48_000)
  end

  it 'uses the recommended sampling temperature by default' do
    expect(described_class).to receive(:http_synthesize).with(
      text:        'Uma frase.',
      lang:        'pt',
      out_path:    '/tmp/moss.wav',
      speaker_wav: nil,
      temperature: 1.7
    )

    described_class.synthesize(text: 'Uma frase.', lang: 'pt', out_path: '/tmp/moss.wav', temperature: 0)
  end
end
