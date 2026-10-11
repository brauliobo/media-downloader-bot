require 'tmpdir'

# Fakes the external boundaries of an audiobook (the TTS service and the book-detection LLM), so a spec drives
# the real Book, Runner and ffmpeg pipeline and looks at what reached the services.
module AudiobookHelpers
  # Records what the TTS backend was asked to say and answers with a silent wav, as the service does.
  class FakeTTS
    attr_reader :calls, :batches
    attr_accessor :seconds, :failure, :before

    def initialize(seconds: 0.2)
      @seconds = seconds
      @calls   = []
      @batches = []
    end

    def reference = calls.find { |call| reference?(call) }

    def narration = calls.reject { |call| reference?(call) }

    def synthesize(out_path:, **options)
      before&.call(options)
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

  # What the chat accepts: remembers every upload and edit, and answers with the message it made.
  class FakeChat
    attr_reader :uploads, :edits

    def initialize
      @uploads = []
      @edits   = []
    end

    def upload_generated_media(**params)
      uploads << params.merge(staged: File.exist?(params[:audio_path]))
      {message_id: 100 + uploads.size, remote_id: "remote-#{uploads.size}"}
    end

    def edit_generated_message(**params)
      edits << params
      {message_id: params[:message_id], remote_id: "edited-#{edits.size}"}
    end

    def titles = uploads.map { |upload| upload[:title] }
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
  # Answers the inputs the book questions were asked with.
  def fake_llm(lang: '', title: '', author: '', gender: 'male', reference: '')
    asked = []
    allow(AI::JSONSchema).to receive(:ask) do |task:, input:, **|
      next { 'text' => reference } unless task == Language::BOOK_PROMPT

      asked << input
      { 'lang' => lang, 'title' => title, 'author' => author, 'gender' => gender }
    end
    asked
  end

  # Translates by marking the text with the languages, or by the given names.
  def fake_translator(names = {})
    allow(Translator).to receive(:translate) do |text, from:, to:|
      mapped = Array(text).map { |line| names.fetch(line) { "#{to.upcase}(#{from}->#{to}):#{line}" } }
      text.is_a?(Array) ? mapped : mapped.first
    end
  end

  # Printing the translated book to PDF is left to chromium, wkhtmltopdf or pandoc.
  def fake_html_to_pdf = allow(Audiobook::HtmlToPdf).to receive(:call) { |_html, pdf| File.write(pdf, '%PDF-') }

  # A one-page PDF with the text on it, the smallest real document there is to parse, print and take a cover from.
  def write_pdf(path, text)
    stream  = "BT /F1 12 Tf 72 700 Td (#{text}) Tj ET"
    objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
      "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream",
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
    ]
    pdf     = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map { |object, idx| pdf.bytesize.tap { pdf << "#{idx + 1} 0 obj\n#{object}\nendobj\n" } }
    xref    = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n" << offsets.map { |offset| format("%010d 00000 n \n", offset) }.join
    File.binwrite(path, pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n")
    path
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
