require 'spec_helper'
require_relative '../../lib/tts/omni_voice'

RSpec.describe TTS::OmniVoice do
  it 'sends temperature zero as OmniVoice sampling parameters by default' do
    Dir.mktmpdir('omnivoice-spec-') do |dir|
      out_path = File.join(dir, 'out.wav')
      agent = double
      response = double(code: '200', body: 'wav')
      captured_form = nil

      allow(Utils::HTTP).to receive(:client).and_return(agent)
      allow(agent).to receive(:post) do |_url, form|
        captured_form = form
        response
      end

      described_class.synthesize(text: 'Hello', lang: 'en', out_path: out_path)

      expect(captured_form['temperature']).to be_nil
      expect(captured_form['position_temperature']).to eq('0')
      expect(captured_form['class_temperature']).to eq('0')
      expect(File.read(out_path)).to eq('wav')
    end
  end

  it 'allows callers to override OmniVoice temperature' do
    Dir.mktmpdir('omnivoice-spec-') do |dir|
      out_path = File.join(dir, 'out.wav')
      agent = double
      response = double(code: '200', body: 'wav')
      captured_form = nil

      allow(Utils::HTTP).to receive(:client).and_return(agent)
      allow(agent).to receive(:post) do |_url, form|
        captured_form = form
        response
      end

      described_class.synthesize(text: 'Hello', lang: 'en', out_path: out_path, temperature: 0.3)

      expect(captured_form['position_temperature']).to eq('0.3')
      expect(captured_form['class_temperature']).to eq('0.3')
    end
  end

  it 'accepts temp as the user-facing alias for temperature' do
    Dir.mktmpdir('omnivoice-spec-') do |dir|
      out_path = File.join(dir, 'out.wav')
      agent = double
      response = double(code: '200', body: 'wav')
      captured_form = nil

      allow(Utils::HTTP).to receive(:client).and_return(agent)
      allow(agent).to receive(:post) do |_url, form|
        captured_form = form
        response
      end

      described_class.synthesize(text: 'Hello', lang: 'en', out_path: out_path, temp: 0.2)

      expect(captured_form['position_temperature']).to eq('0.2')
      expect(captured_form['class_temperature']).to eq('0.2')
      expect(captured_form).not_to have_key('temp')
    end
  end
end
