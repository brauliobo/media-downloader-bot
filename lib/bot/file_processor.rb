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
    # 2. Run OCR + TTS via `Audiobook.generate` (progress through stl).
    # 3. Upload transcription JSON and audiobook ZIP as reply docs.
    # 4. Cleans up and returns nil.
    def handle_pdf
      return unless pdf_document?

      pdf_dl  = Bot::PdfProcessor.new(dir:, bot:, msg:)
      input   = pdf_dl.download

      audio_zip = "#{dir}/#{File.basename(input.fn_in, '.pdf')}.zip"

      progress_msg = send_message msg, me('Running OCR and TTS, please wait...')

      st  = Status.new { |text| edit_message msg, progress_msg.message_id, text: me(text) }
      stl = Status::Line.new '', status: st

      result = Audiobook.generate(input.fn_in, audio_zip, stl: stl)

      json_io  = Faraday::UploadIO.new result.transcription, 'application/json'
      send_message msg, me('Book transcription'), type: 'document', document: json_io

      audio_io = Faraday::UploadIO.new result.audio, 'application/zip'
      send_message msg, me('Audiobook (ZIP)'), type: 'document', document: audio_io

      edit_message msg, progress_msg.message_id, text: me('Done ✅')
      nil
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
