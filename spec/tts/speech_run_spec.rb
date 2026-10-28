require 'rails_helper'

RSpec.describe TTS::SpeechRun do
  let(:status) { double(:status, update: nil) }
  let(:voice) { TTS::Reference.new(path: '/tmp/voice.wav', text: 'Hello.') }

  def job(text, **extra) = {text: text, lang: 'en', out_path: "/tmp/#{text}.wav", **extra}

  def spoken_calls
    calls = []
    allow(TTS).to receive(:synthesize_batch) do |items:, on_batch:, **options|
      calls << {texts: items.map { |item| item[:text] }, options: options}
      on_batch.call(items)
    end
    calls
  end

  it 'speaks the jobs as they are' do
    calls = spoken_calls

    described_class.new([job('one'), job('two')]).call(speed: 1)

    expect(calls).to eq([{texts: %w[one two], options: {speed: 1}}])
  end

  it 'translates the jobs first, leaving out the ones with nothing to say, and reports both counts' do
    calls = spoken_calls
    translate = ->(job) { job.tap { job[:text] = {'a' => 'um', 'b' => ''}.fetch(job[:text]) } }

    described_class.new([job('a', status: 'page 1'), job('b')], status: status, prefix: 'dub: ', translate: translate).call

    expect(calls.flat_map { |call| call[:texts] }).to eq(['um'])
    expect(status).to have_received(:update).with('dub: page 1, translated 2/2, audio 1/2')
  end

  it 'counts what an earlier run spoke in the progress' do
    spoken_calls

    described_class.new([job('three', status: 'page 3'), job('four', status: 'page 4')], resumed: 2, status: status).call

    expect(status).to have_received(:update).with('page 4, audio 4/4')
  end

  it 'speaks the jobs of a reference in its voice and passes each batch on' do
    calls = spoken_calls
    stored = []

    described_class.new([job('one', reference: voice), job('two')], on_batch: ->(batch) { stored.concat(batch) }).call

    expect(calls.find { |call| call[:texts] == ['one'] }[:options]).to include(speaker_wav: '/tmp/voice.wav', ref_text: 'Hello.')
    expect(calls.find { |call| call[:texts] == ['two'] }[:options]).not_to include(:speaker_wav)
    expect(stored.map { |item| item[:text] }).to match_array(%w[one two])
  end
end
