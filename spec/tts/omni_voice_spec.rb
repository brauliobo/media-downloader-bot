require 'spec_helper'
require 'timeout'
require_relative '../../lib/tts/omni_voice'

RSpec.describe TTS::OmniVoice do
  it 'leaves OmniVoice generation parameters at their model defaults' do
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

      expect(captured_form).not_to have_key('temperature')
      expect(captured_form).not_to have_key('position_temperature')
      expect(captured_form).not_to have_key('class_temperature')
      expect(File.read(out_path)).to eq('wav')
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

  it 'allows concurrent requests without backend throttling' do
    Dir.mktmpdir('omnivoice-spec-') do |dir|
      agent = double
      response = double(code: '200', body: 'wav')
      started = Queue.new
      release = Queue.new

      allow(Utils::HTTP).to receive(:client).and_return(agent)
      allow(agent).to receive(:post) do
        started << true
        release.pop
        response
      end

      threads = 2.times.map do |idx|
        Thread.new do
          described_class.synthesize(
            text: "Request #{idx}",
            lang: 'en',
            out_path: File.join(dir, "#{idx}.wav")
          )
        end
      end

      2.times { Timeout.timeout(1) { started.pop } }
      2.times { release << true }
      threads.each(&:join)
    ensure
      2.times { release << true }
      threads&.each(&:join)
    end
  end

  it 'sends model batches in one request and writes each returned wav' do
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
        ]
      )

      expect(JSON.parse(captured_form['items'])).to eq([
        { 'text' => 'One.', 'language' => 'en' },
        { 'text' => 'Two.', 'language' => 'en' },
      ])
      expect(File.read(paths[0])).to eq('wav1')
      expect(File.read(paths[1])).to eq('wav2')
    end
  end

end
