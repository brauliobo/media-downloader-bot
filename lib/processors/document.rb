require_relative 'base'

module Processors
  class Document < Base
    def self.pdf_document?(doc_or_msg)
      doc = doc_or_msg.respond_to?(:document) ? doc_or_msg.document : doc_or_msg
      doc && (doc.mime_type == 'application/pdf' || doc.file_name.to_s.downcase.end_with?('.pdf'))
    end

    def self.epub_document?(doc_or_msg)
      doc = doc_or_msg.respond_to?(:document) ? doc_or_msg.document : doc_or_msg
      fname = doc&.file_name.to_s.downcase
      doc && (doc.mime_type == 'application/epub+zip' || fname.end_with?('.epub'))
    end

    def self.yaml_document?(doc_or_msg)
      doc = doc_or_msg.respond_to?(:document) ? doc_or_msg.document : doc_or_msg
      fname = doc&.file_name.to_s.downcase
      doc && (doc.mime_type == 'application/x-yaml' || fname.end_with?('.yml') || fname.end_with?('.yaml'))
    end

    def self.can_handle?(msg)
      pdf_document?(msg) || epub_document?(msg) || yaml_document?(msg)
    end

    def pdf_document?
      self.class.pdf_document?(msg)
    end

    def epub_document?
      self.class.epub_document?(msg)
    end

    def yaml_document?
      self.class.yaml_document?(msg)
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
      return super unless pdf_document? || epub_document? || yaml_document?
      raise 'no input provided' unless i

      @stl&.update 'OCR & TTS' unless yaml_document?
      @stl&.update 'Generating audiobook from YAML' if yaml_document?
      begin
        if yaml_document?
          i.uploads = Audiobook::Yaml.generate_audio(i.fn_in, dir: dir, stl: @stl, opts: i.opts)
        else
          i.uploads = Audiobook.generate_uploads(i.fn_in, dir: dir, stl: @stl, opts: i.opts)
        end
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


