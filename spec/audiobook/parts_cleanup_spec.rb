require 'rails_helper'

# A book's parts (a wav per sentence, per paragraph, per page) are many times its size: each is dropped once the next is there.
RSpec.describe 'Audiobook parts cleanup' do
  let(:page) { Audiobook::Page.new(1, [Audiobook::Paragraph.new([Audiobook::Sentence.new('Hello.'), Audiobook::Sentence.new('World!')])]) }
  let(:spoken) { [] }

  def sine_wav(path)
    system('ffmpeg', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=24000:duration=0.1', '-c:a', 'pcm_s16le', path) || raise('sine fixture failed')
  end

  def wavs(dir) = Dir.children(dir).grep(/\.wav\z/).sort

  before do
    allow(TTS).to receive(:synthesize) do |text:, out_path:, **_kwargs|
      spoken << text
      sine_wav(out_path)
    end
  end

  it 'leaves the page wav and the pauses shared between paragraphs, not the wavs of the sentences and paragraphs it was made of' do
    Dir.mktmpdir('audiobook-parts-') do |dir|
      wav = page.to_wav(dir, '0001', lang: 'en')

      expect(spoken).to eq(['Hello.', 'World!'])
      expect(wav).to eq(File.join(dir, 'page_0001.wav'))
      expect(wavs(dir)).to all(match(/\Apage_|\Apause_/))
      expect(wavs(dir)).to include('page_0001.wav')
      expect(Dir.children(dir).grep(/\.opus\z/)).to be_empty
    end
  end

  it 'keeps a sentence as Opus until its paragraph is joined, and does not synthesize it again' do
    Dir.mktmpdir('audiobook-parts-') do |dir|
      sentence = page.items.first.sentences.first
      stored   = sentence.to_wav(dir, '1_0', lang: 'en')

      expect(stored).to eq File.join(dir, '1_0.opus')
      expect(Dir.children(dir)).to eq ['1_0.opus']
      expect(page.sentence_job(sentence, File.join(dir, '1_0.wav'), 'en', 'x')).to be_nil
      expect(sentence.to_wav(dir, '1_0', lang: 'en')).to eq stored
      expect(spoken).to eq ['Hello.']
    end
  end

  it 'keeps a joined page on resume, without synthesizing its sentences again' do
    Dir.mktmpdir('audiobook-parts-') do |dir|
      page.to_wav(dir, '0001', lang: 'en')
      spoken.clear

      expect(page.to_wav(dir, '0001', lang: 'en')).to eq(File.join(dir, 'page_0001.wav'))
      expect(page.speech_jobs(dir, '0001', 'en')).to be_empty
      expect(spoken).to be_empty
    end
  end

  it 'keeps a joined paragraph on resume, without asking for its sentences again' do
    Dir.mktmpdir('audiobook-parts-') do |dir|
      page.prepare_speech_items(dir, '0001', lang: 'en')
      paragraph = page.items.first
      paragraph.to_wav
      spoken.clear

      expect(paragraph.to_wav).to eq(paragraph.wav_path)
      expect(page.paragraph_jobs(paragraph, 'en')).to be_empty
      expect(spoken).to be_empty
    end
  end
end
