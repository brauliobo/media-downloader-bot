require 'spec_helper'
require 'base64'
require 'json'
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

  it 'sends long text as one request because OmniVoice chunks internally' do
    Dir.mktmpdir('omnivoice-spec-') do |dir|
      out_path = File.join(dir, 'out.wav')
      agent = double
      response = double(code: '200', body: 'wav')
      captured_forms = []
      text = (['This is a sentence.'] * 60).join(' ')

      allow(Utils::HTTP).to receive(:client).and_return(agent)
      allow(agent).to receive(:post) do |_url, form|
        captured_forms << form
        response
      end

      described_class.synthesize(text: text, lang: 'en', out_path: out_path)

      expect(captured_forms.size).to eq(1)
      expect(captured_forms.first['text']).to eq(text)
    end
  end

  it 'sends batch synthesis as one request and writes returned wavs' do
    Dir.mktmpdir('omnivoice-spec-') do |dir|
      paths = [File.join(dir, 'one.wav'), File.join(dir, 'two.wav')]
      agent = double
      response = double(
        code: '200',
        body: JSON.dump(
          'items' => [
            { 'audio' => Base64.strict_encode64('wav1') },
            { 'audio' => Base64.strict_encode64('wav2') },
          ]
        )
      )
      captured_form = nil

      allow(Utils::HTTP).to receive(:client).and_return(agent)
      allow(agent).to receive(:post) do |_url, form|
        captured_form = form
        response
      end

      described_class.synthesize_batch(
        items: [
          { text: 'One.', lang: 'en', out_path: paths[0] },
          { text: 'Two.', lang: 'en', out_path: paths[1] },
        ],
        temperature: 0.2
      )

      payload = JSON.parse(captured_form['items'])
      expect(payload).to eq([
        { 'text' => 'One.', 'language' => 'en' },
        { 'text' => 'Two.', 'language' => 'en' },
      ])
      expect(captured_form['position_temperature']).to eq('0.2')
      expect(captured_form['class_temperature']).to eq('0.2')
      expect(File.read(paths[0])).to eq('wav1')
      expect(File.read(paths[1])).to eq('wav2')
    end
  end
end
