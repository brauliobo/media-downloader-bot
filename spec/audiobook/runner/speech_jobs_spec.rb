require 'rails_helper'

RSpec.describe Audiobook::Runner::SpeechJobs do
  let(:book) { Struct.new(:speech_language, :translated) { def translate! = nil }.new('pt', false) }
  let(:host) do
    book = self.book
    Class.new do
      include Audiobook::Runner::SpeechJobs

      define_method(:initialize) { @book = book; @lang = 'en' }
      public :pipeline_speech_jobs, :store_batch
    end
  end

  def job(text) = { sentence: Audiobook::Sentence.new(text, language: 'en'), text: text, lang: 'en', out_path: "/tmp/#{text}.wav", status: text }

  it 'does not ask the TTS to speak a sentence the translator returned blank or as punctuation, which it refuses' do
    translations = { 'blank' => '', 'dots' => '...', 'one' => 'um' }
    allow(Audiobook::Book).to receive(:translate_sentences) { |sentences, **| sentences.each { |sentence| sentence.text = translations.fetch(sentence.text) } }
    spoken = []
    allow(TTS).to receive(:synthesize_batch) { |items:, **| spoken.concat(items.map { |item| item[:text] }) }

    host.new.pipeline_speech_jobs(%w[blank dots one].map { |text| job(text) }, {}, ->(_batch) { })

    expect(spoken).to eq(['um'])
  end

  it 'stores each batch at the speed asked as it arrives, then counts it' do
    status   = double(:status)
    progress = Utils::ProgressCounter.new(total: 2, status: status) { |done, total| "#{done}/#{total}" }
    allow(status).to receive(:update)
    batch    = [job('one'), job('two')]
    allow(Audiobook::AudioFiles).to receive(:compress_all)

    host.new.store_batch(progress, 1.2).call(batch)

    expect(Audiobook::AudioFiles).to have_received(:compress_all).with(['/tmp/one.wav', '/tmp/two.wav'], 1.2)
    expect(status).to have_received(:update).with('2/2')
  end
end
