require 'spec_helper'
require_relative '../../lib/subtitler/whisper_x'

RSpec.describe Subtitler::WhisperX do
  subject(:backend) do
    Class.new do
      extend Subtitler::WhisperX
    end
  end

  around do |example|
    previous_api = backend.api
    backend.api = URI.parse('http://whisperx.test:8080')
    example.run
  ensure
    backend.api = previous_api
  end

  before do
    allow(Zipper).to receive(:with_audio_wav).with('audio.wav').and_yield('/tmp/audio.wav')
  end

  it 'preserves WhisperX request parameters and returns a normalized subtitle' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'pt-BR', text: ' Olá',
      segments: [{start: 0.0, end: 1.0, text: ' Olá', words: [{word: ' Olá', start: 0.0, end: 1.0}]}]
    ))
    expect(Utils::HTTP).to receive(:post).with(
      'http://whisperx.test:8080/inference',
      {
        file: '/tmp/audio.wav', temperature: '0.0', response_format: 'verbose_json',
        temperature_inc: '0.2',
      }
    ).and_return(response)

    subtitle = backend.transcribe('audio.wav')

    expect(subtitle).to be_a(Subtitler::Subtitle)
    expect(subtitle).to have_attributes(language: 'pt', text: 'Olá')
  end

  it 'honors merge_words through the shared structured ingress' do
    response = instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(
      language: 'en',
      segments: [{
        start: 0.0, end: 1.0, text: 'testing',
        words: [{word: 'test', start: 0.0, end: 0.5}, {word: 'ing', start: 0.5, end: 1.0}],
      }]
    ))
    allow(Utils::HTTP).to receive(:post).and_return(response)

    expect(backend.transcribe('audio.wav', merge_words: false).entries.first.words.map(&:text)).to eq(%w[test ing])
    expect(backend.transcribe('audio.wav', merge_words: true).entries.first.words.map(&:text)).to eq(%w[testing])
  end
end
