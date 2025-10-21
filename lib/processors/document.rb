require_relative 'base'

module Processors
  class Document < Base
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

    def process(*args, **kwargs)
      download
    end

    def handle_input(i, pos: nil, **_kwargs)
      return super unless pdf_document? || epub_document?
      raise 'no input provided' unless i

      @stl&.update 'OCR & TTS'
      begin
        i.uploads = Audiobook.generate_uploads(i.fn_in, dir: dir, stl: @stl, opts: i.opts)
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


