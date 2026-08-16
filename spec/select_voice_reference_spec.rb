require 'spec_helper'
require_relative '../lib/voice_reference'

RSpec.describe 'bin/select_voice_reference' do
  it 'routes local files through the shared recorded-source orchestration' do
    Dir.mktmpdir('select-voice-reference-') do |dir|
      source = File.join(dir, 'recordings')
      output = File.join(dir, 'reference.wav')
      FileUtils.mkdir_p(source)
      File.write(File.join(source, 'second.wav'), 'audio')
      File.write(File.join(source, 'first.mp3'), 'audio')
      candidate = VoiceReference::Candidate.new(audio: 'first.mp3', start: 0, finish: 1, text: 'Reference')
      allow(VoiceReference).to receive(:from_files).and_return(candidate)
      original_argv = ARGV.dup
      ARGV.replace(["source=#{source}", "output=#{output}", 'language=pt', 'reference-filter=quality', 'strict=0'])

      expect { load File.expand_path('../bin/select_voice_reference', __dir__) }.to output(/"text": "Reference"/).to_stdout

      expect(VoiceReference).to have_received(:from_files).with(
        audio_files: [File.join(source, 'first.mp3'), File.join(source, 'second.wav')],
        output: output, language: 'pt', transcriber: kind_of(VoiceReference::Transcriber),
        reference_filter: :quality, strict: false
      )
    ensure
      ARGV.replace(original_argv)
    end
  end

  it 'preserves quality-report order and top limits' do
    Dir.mktmpdir('select-voice-report-') do |dir|
      output = File.join(dir, 'reference.wav')
      report = File.join(dir, 'quality.json')
      paths  = ['/recordings/second.wav', '/recordings/first.wav']
      File.write(report, JSON.generate(recordings: paths.map { |path| {path: path} }))
      candidate = VoiceReference::Candidate.new(audio: paths.first, start: 0, finish: 1, text: 'Reference')
      allow(VoiceReference).to receive(:from_files).and_return(candidate)
      original_argv = ARGV.dup
      ARGV.replace([
        "source=#{dir}", "output=#{output}", "quality-report=#{report}", 'top=1'
      ])

      expect { load File.expand_path('../bin/select_voice_reference', __dir__) }.to output(/Reference/).to_stdout

      expect(VoiceReference).to have_received(:from_files).with(
        audio_files: [paths.first], output: output, language: 'en',
        transcriber: kind_of(VoiceReference::Transcriber), reference_filter: :raw, strict: true
      )
    ensure
      ARGV.replace(original_argv)
    end
  end
end
