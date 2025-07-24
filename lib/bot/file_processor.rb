class Bot
  class FileProcessor < Processor

    require 'faraday'
    require 'faraday/multipart'
    require_relative '../audiobook'

    # If the incoming message is a PDF document we run a dedicated OCR + TTS
    # pipeline and send the resulting files back immediately. No further
    # processing is needed, so Worker can return right after calling `handle_pdf`.

    def pdf_document?
      info = msg.document
      info && info.mime_type == 'application/pdf'
    end

    # Entry-point for Worker when we have a PDF. Performs:
    # 1. Download the Telegram document (delegated to PdfProcessor).
    # 2. Run OCR + TTS via `Audiobook.generate`.
    # 3. Attach the generated artifacts to the input as `uploads` so that the
    #    Worker can handle sending them. No direct upload happens here.
    #
    # Returns the input object augmented with its `uploads` array so that the
    # caller (Worker) proceeds with the regular pipeline.
    def handle_pdf
      return unless pdf_document?

      pdf_dl  = Bot::PdfProcessor.new(dir:, bot:, msg:)
      input   = pdf_dl.download

      audio_zip = "#{dir}/#{File.basename(input.fn_in, '.pdf')}.zip"

      # Use the shared Status instance so progress is integrated with other
      # operations handled by Worker.
      stl = Status::Line.new 'OCR & TTS', status: self.st

      result = Audiobook.generate(input.fn_in, audio_zip, stl: stl)

      # Describe every output for the Worker.
      uploads = []
      uploads << SymMash.new(
        path:    result.transcription,
        mime:    'application/json',
        caption: me('Book transcription'),
      )
      uploads << SymMash.new(
        path:    result.audio,
        mime:    'application/zip',
        caption: me('Audiobook (ZIP)'),
      )

      input.uploads = uploads

      input
    ensure
      pdf_dl&.cleanup if defined?(pdf_dl)
    end

    # ------------------------------------------------------------------
    def download
      return handle_pdf if pdf_document?

      info   = msg.video || msg.audio
      file   = SymMash.new api.get_file file_id: info.file_id
      fn_in  = file.result.file_path
      page   = http.get "https://api.telegram.org/file/bot#{ENV['TOKEN']}/#{fn_in}"

      fn_out = "#{dir}/input.#{File.extname fn_in}"
      File.write fn_out, page.body

      SymMash.new(
        fn_in: fn_out,
        info: {
          title: info.file_name,
        },
      )
    end

    # PDF bypasses the typical transcoding flow, so we override `handle_input`
    # to no-op in that case. For audio/video, fall back to the parent logic.
    def handle_input i=nil, **kwargs
      return if pdf_document?
      super
    end

  end
end
