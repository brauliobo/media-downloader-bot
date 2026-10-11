require 'rails_helper'
require_relative '../support/whisper_server'

RSpec.describe Subtitler::WhisperX do
  include WhisperServer

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

  let(:dir)   { Dir.mktmpdir('whisper-spec-') }
  let(:audio) { media_file(File.join(dir, 'audio.mp3')) }

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  it 'preserves WhisperX request parameters and returns a normalized subtitle' do
    whisper_says(
      language: 'pt-BR', text: ' Olá',
      segments: [{start: 0.0, end: 1.0, text: ' Olá', words: [{word: ' Olá', start: 0.0, end: 1.0}]}]
    )

    subtitle = backend.transcribe(audio)

    expect(whisper_server.requests).to eq([{
      url: 'http://whisperx.test:8080/inference', file: 'RIFF', temperature: '0.0', response_format: 'verbose_json',
      temperature_inc: '0.2',
    }])
    expect(subtitle).to be_a(Subtitler::Subtitle)
    expect(subtitle).to have_attributes(language: 'pt', text: 'Olá')
  end

  it 'honors merge_words through the shared structured ingress' do
    whisper_says(
      language: 'en',
      segments: [{
        start: 0.0, end: 1.0, text: 'testing',
        words: [{word: 'test', start: 0.0, end: 0.5}, {word: 'ing', start: 0.5, end: 1.0}],
      }]
    )

    expect(backend.transcribe(audio, merge_words: false).entries.first.words.map(&:text)).to eq(%w[test ing])
    expect(backend.transcribe(audio, merge_words: true).entries.first.words.map(&:text)).to eq(%w[testing])
  end
end
