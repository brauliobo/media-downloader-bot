require 'rails_helper'

RSpec.describe Audiobook::Runner::SpeechJobs do
  let(:book) { Struct.new(:speech_language, :translated) { def translate! = nil }.new('pt', false) }
  let(:host) do
    book = self.book
    Class.new do
      include Audiobook::Runner::SpeechJobs

      define_method(:initialize) { @book = book; @lang = 'en' }
      public :process_speech_jobs, :store_batch
    end
  end

  def job(text) = { sentence: Audiobook::Sentence.new(text, language: 'en'), text: text, lang: 'en', out_path: "/tmp/#{text}.wav", status: text }

  it 'does not ask the TTS to speak a sentence the translator returned blank or as punctuation, which it refuses' do
    book.define_singleton_method(:translation_needed?) { true }
    translations = { 'blank' => '', 'dots' => '...', 'one' => 'um' }
    allow(Audiobook::Book).to receive(:translate_sentences) { |sentences, **| sentences.each { |sentence| sentence.text = translations.fetch(sentence.text) } }
    spoken = []
    allow(TTS).to receive(:synthesize_batch) { |items:, **| spoken.concat(items.map { |item| item[:text] }) }
    page = double(speech_jobs: %w[blank dots one].map { |text| job(text) })

    host.new.process_speech_jobs([page], '/tmp', {})

    expect(spoken).to eq(['um'])
  end

  it 'stores each batch at the speed asked as it arrives' do
    batch = [job('one'), job('two')]
    allow(Audiobook::AudioFiles).to receive(:compress_all)

    host.new.store_batch(1.2).call(batch)

    expect(Audiobook::AudioFiles).to have_received(:compress_all).with(['/tmp/one.wav', '/tmp/two.wav'], 1.2)
  end

  it 'reports the sentences translated along with the audio stored' do
    book.define_singleton_method(:translation_needed?) { true }
    status = double(:status)
    allow(status).to receive(:update)
    allow(Audiobook::Book).to receive(:translate_sentences) { |sentences, **| sentences.each { |sentence| sentence.text = 'um' } }
    allow(TTS).to receive(:synthesize_batch) { |items:, on_batch:, **| on_batch.call(items) }
    allow(Audiobook::AudioFiles).to receive(:compress_all)
    page = double(speech_jobs: [job('one'), job('two')])

    host.new.tap { |runner| runner.instance_variable_set(:@stl, status) }.send(:process_speech_jobs, [page], '/tmp', {})

    expect(status).to have_received(:update).with('two, translated 2/2, audio 2/2')
  end
end
