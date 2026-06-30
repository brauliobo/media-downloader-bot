require 'spec_helper'

RSpec.describe 'Audiobook punctuation-only text' do
  PUNCTUATION_ONLY = ['.', '...', '…', ' . … ', '"..."', '(...)', '[...]', '—', '***'].freeze

  it 'treats punctuation-only variants as unspeakable' do
    PUNCTUATION_ONLY.each do |text|
      expect(Audiobook::Sentence.speakable_text?(text)).to eq(false), text.inspect
    end
  end

  it 'keeps punctuation on speakable sentences' do
    sentence = Audiobook::Sentence.build('Olá mundo...')

    expect(sentence.text).to eq('Olá mundo...')
    expect(sentence.spoken_text).to eq('Olá mundo...')
  end

  it 'filters punctuation-only sentences from real YAML input' do
    Dir.mktmpdir('audiobook-punctuation-yaml-') do |dir|
      path = File.join(dir, 'book.yml')
      File.write(path, <<~YAML)
        ---
        language: pt
        pages:
        - page:
            number: 1
            items:
            - paragraph:
                sentences:
                - text: "."
                - text: "..."
                - text: "…"
                - text: "—"
                - text: "Olá mundo."
                - text: "Fim!"
      YAML

      book = Audiobook::Book.from_yaml(path)
      sentences = book.pages.flat_map(&:items).grep(Audiobook::Paragraph).flat_map(&:sentences)

      expect(sentences.map(&:text)).to eq(['Olá mundo.', 'Fim!'])
    end
  end

  it 'does not synthesize punctuation-only OCR artifacts or emit loud plateau waveforms' do
    page = Audiobook::Page.new(1, [
      Audiobook::Paragraph.new([
        Audiobook::Sentence.new('Hello.'),
        *PUNCTUATION_ONLY.map { |text| Audiobook::Sentence.new(text) },
        Audiobook::Sentence.new('World!'),
      ])
    ])

    Dir.mktmpdir('audiobook-punctuation-waveform-') do |dir|
      captured = []
      allow(TTS).to receive(:synthesize) do |text:, out_path:, **_kwargs|
        captured << text
        Audiobook::Sentence.speakable_text?(text) ? sine_wav(out_path) : plateau_wav(out_path)
      end

      wav = page.to_wav(dir, '0001', lang: 'en')

      expect(captured).to eq(['Hello.', 'World!'])
      expect(loud_plateau_blocks(wav)).to eq(0)
    end
  end

  def sine_wav(path)
    cmd = "#{Zipper::FFMPEG} -f lavfi -i sine=frequency=440:sample_rate=24000:duration=0.1 " \
          "-c:a pcm_s16le #{Sh.escape(path)}"
    _, err, status = Sh.run(cmd)
    Sh.assert_success!('sine fixture failed', err, status: status, output: path)
  end

  def plateau_wav(path)
    raw = File.join(File.dirname(path), "#{File.basename(path, '.wav')}.s16le")
    File.binwrite(raw, [20_000].pack('s<') * 2_400)
    cmd = "#{Zipper::FFMPEG} -f s16le -ar 24000 -ac 1 -i #{Sh.escape(raw)} " \
          "-c:a pcm_s16le #{Sh.escape(path)}"
    _, err, status = Sh.run(cmd)
    Sh.assert_success!('plateau fixture failed', err, status: status, output: path)
  end

  def loud_plateau_blocks(path)
    pcm, err, status = Sh.run("#{Zipper::FFMPEG} -i #{Sh.escape(path)} -ac 1 -ar 24000 -f s16le -")
    Sh.assert_success!('waveform decode failed', err, status: status)

    pcm.unpack('s<*').each_slice(240).count do |samples|
      next false if samples.empty?

      rms = Math.sqrt(samples.sum { |sample| sample * sample }.to_f / samples.size)
      zero_crossings = samples.each_cons(2).count { |a, b| (a.negative? && b >= 0) || (a >= 0 && b.negative?) }
      rms > 10_000 && zero_crossings <= 1
    end
  end
end
