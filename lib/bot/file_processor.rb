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

      pdf_dl = Bot::PdfProcessor.new(dir:, bot:, msg:, st: self.st)
      input  = pdf_dl.download

      input
    ensure
      pdf_dl&.cleanup if defined?(pdf_dl)
    end

    # ------------------------------------------------------------------
    def download
      return handle_pdf if pdf_document?

      info = msg.video || msg.audio
      unless info
        st.error('Unsupported message type')
        return
      end

      local_path = bot.download_file(info, dir: dir)

      SymMash.new(
        fn_in: local_path,
        opts:  SymMash.new(onlysrt: 1),
        info: {
          title: info.respond_to?(:file_name) ? info.file_name : File.basename(local_path, File.extname(local_path)),
        },
      )
    end


  # PDF bypasses the typical transcoding flow, so we override `handle_input`
    # to no-op in that case. For audio/video, fall back to the parent logic.
    # Handle transcoding normally; for PDFs run OCR+TTS here where stline exists.
    def handle_input(i = nil, **kwargs)
      if pdf_document?
        raise 'no input provided' unless i

        @stl&.update 'OCR & TTS'
        src  = i.info&.title || i.fn_in
        base = File.basename(src, File.extname(src))
        audio_out = "#{dir}/#{base}.opus"
        
        begin
          result = Audiobook.generate(i.fn_in, audio_out, stl: @stl, opts: i.opts)
          
          # Check if files were actually created
          unless File.exist?(result.transcription) && File.exist?(result.audio)
            @stl&.error 'Failed to generate audiobook files'
            return nil
          end
          
          # Check if audio file has content (not just a tiny silent file)
          audio_size = File.size(result.audio)
          if audio_size < 1000 # Less than 1KB suggests empty/silent audio
            @stl&.update 'Warning: Generated audio is very small, may be empty'
          end

          # Get audio duration like other processors do
          audio_duration = 0
          begin
            probe = Prober.for(result.audio)
            audio_duration = probe.format.duration.to_i if probe&.format&.duration
          rescue => e
            puts "[DURATION_ERROR] Failed to get audio duration: #{e.message}"
          end

          i.uploads = [
            SymMash.new(
              fn_out: result.transcription,
              type: SymMash.new(name: 'document'),
              info: SymMash.new(title: base, uploader: ''),
              mime: 'application/json',
              opts: SymMash.new(format: SymMash.new(mime: 'application/json')),
              oprobe: Prober.for(result.transcription)
            ),
            SymMash.new(
              fn_out: result.audio,
              type: SymMash.new(name: 'audio'),
              info: SymMash.new(title: base, uploader: ''),
              mime: 'audio/ogg',
              opts: SymMash.new(format: SymMash.new(mime: 'audio/ogg')),
              oprobe: Prober.for(result.audio)
            ),
          ]
          return i
        rescue => e
          @stl&.error "Audiobook generation failed: #{e.message}"
          puts "[PDF_ERROR] #{e.class}: #{e.message}"
          puts e.backtrace.first(3)
          return nil
        end
      end
      super
    end

  end
end
