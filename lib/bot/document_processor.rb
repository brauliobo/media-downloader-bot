class Manager
  class DocumentProcessor < Processor

    def pdf_document?
      info = msg.document
      info && (info.mime_type == 'application/pdf' || info.file_name.to_s.downcase.end_with?('.pdf'))
    end

    def epub_document?
      info = msg.document
      fname = info&.file_name.to_s.downcase
      info && (info.mime_type == 'application/epub+zip' || fname.end_with?('.epub'))
    end

    def download
      info = msg.document
      raise 'No document' unless info

      local_path = if bot.respond_to?(:td_bot?) && bot.td_bot?
        fid = info.respond_to?(:document) && info.document.respond_to?(:id) ? info.document.id : info.document[:id]
        bot.download_file(fid, dir: dir)
      else
        bot.download_file(info, dir: dir)
      end

      SymMash.new(
        fn_in: local_path,
        info:  {title: info.file_name},
      )
    end

    # For documents, only download here; heavy processing happens later with a status line
    def process(*args, **kwargs)
      download
    end

    def handle_input(i = nil, **_kwargs)
      return super unless pdf_document? || epub_document?
      raise 'no input provided' unless i

      @stl&.update 'OCR & TTS'
      src  = i.info&.title || i.fn_in
      base = File.basename(src, File.extname(src))
      audio_out = "#{dir}/#{base}.opus"

      begin
        result = Audiobook.generate(i.fn_in, audio_out, stl: @stl, opts: i.opts)
        unless File.exist?(result.yaml) && File.exist?(result.audio)
          @stl&.error 'Failed to generate audiobook files'
          return nil
        end

        i.uploads = [
          SymMash.new(
            fn_out: result.yaml,
            type: SymMash.new(name: :document),
            info: SymMash.new(title: base, uploader: ''),
            mime: 'application/x-yaml',
            opts: SymMash.new(format: SymMash.new(mime: 'application/x-yaml'))
          ),
          SymMash.new(
            fn_out: result.audio,
            type: SymMash.new(name: :audio),
            info: SymMash.new(title: base, uploader: ''),
            mime: 'audio/ogg',
            opts: SymMash.new(format: SymMash.new(mime: 'audio/ogg')),
            oprobe: Prober.for(result.audio)
          ),
        ]
        i
      rescue => e
        @stl&.error "Audiobook generation failed: #{e.message}"
        nil
      end
    end

    protected
    def http
      Mechanize.new
    end

  end
end


