require 'tmpdir'

# Fakes the external boundaries of an audiobook (the TTS service and the book-detection LLM), so a spec drives
# the real Book, Runner and ffmpeg pipeline and looks at what reached the services.
module AudiobookHelpers
  # Records what the TTS backend was asked to say and answers with a silent wav, as the service does.
  class FakeTTS
    attr_reader :calls, :batches
    attr_accessor :seconds, :failure

    def initialize(seconds: 0.2)
      @seconds = seconds
      @calls   = []
      @batches = []
    end

    def reference = calls.find { |call| reference?(call) }

    def narration = calls.reject { |call| reference?(call) }

    def synthesize(out_path:, **options)
      calls << options.merge(out_path: out_path)
      write_wav(out_path)
    end

    def synthesize_batch(items:, **options)
      raise failure if failure

      batches << options
      items.each { |item| synthesize(**item.slice(:text, :lang, :out_path), **options) }
    end

    private

    def reference?(call) = call[:out_path].end_with?('audiobook_voice_reference.wav')

    def write_wav(path)
      rate = TTS.output_sample_rate
      data = "\0\0".b * (rate * seconds).to_i
      header = ['RIFF', 36 + data.bytesize, 'WAVE', 'fmt ', 16, 1, 1, rate, rate * 2, 2, 16, 'data', data.bytesize]
      File.binwrite(path, header.pack('a4Va4a4VvvVVvva4V') + data)
    end
  end

  class StatusLog
    attr_reader :lines

    def initialize = @lines = []

    def update(line) = @lines << line
  end

  def fake_tts(backend = TTS::BACKEND, **options)
    FakeTTS.new(**options).tap do |tts|
      stub_const('TTS::BACKEND', backend)
      allow(backend).to receive(:synthesize) { |**args| tts.synthesize(**args) }
      allow(backend).to receive(:synthesize_batch) { |**args| tts.synthesize_batch(**args) }
    end
  end

  # What the model answers when asked about a book (language, title, author, gender) or for a narrator reference.
  def fake_llm(lang: '', title: '', author: '', gender: 'male', reference: '')
    allow(AI::JSONSchema).to receive(:ask) do |task:, **|
      task == Language::BOOK_PROMPT ? { 'lang' => lang, 'title' => title, 'author' => author, 'gender' => gender } : { 'text' => reference }
    end
  end

  def book_of(*items, metadata: {}, opts: nil)
    Audiobook::Book.new(pages: [Audiobook::Page.new(1, items)], metadata: SymMash.new(metadata), opts: opts)
  end

  def sentence_book(*texts, **options)
    book_of(Audiobook::Paragraph.new(texts.map { |text| Audiobook::Sentence.new(text) }), **options)
  end

  # Reads the book aloud into a real file and answers its duration in seconds.
  def narrate(book, opts = SymMash.new, stl: nil)
    Dir.mktmpdir do |dir|
      out = Audiobook::Runner.new(book, stl, opts).process_to_audio(File.join(dir, 'audiobook.opus'))
      Prober.for(out).format.duration.to_f
    end
  end
end

RSpec.configure { |config| config.include AudiobookHelpers }
