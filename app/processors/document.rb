module Processors
  class Document < File
    self.attr = :document

    def self.document_kind(doc)
      return unless doc

      Audiobook::SourceFormats.document_kind(file_name: doc.file_name, mime_type: doc.mime_type)
    end

    def self.can_handle?(msg) = !!document_kind(msg&.document)

    def document_kind = self.class.document_kind(msg.document)

    def handle_input(i, pos: nil, **_kwargs)
      kind = document_kind
      return super unless kind
      raise 'no input provided' unless i

      @stl&.update(kind == :yaml ? 'Generating audiobook from YAML' : 'OCR & TTS')
      begin
        i.uploads = if kind == :yaml
          Audiobook::Yaml.generate_audio(i.fn_in, dir: dir, stl: @stl, opts: i.opts)
        else
          Audiobook.generate_uploads(i.fn_in, dir: dir, stl: @stl, opts: i.opts)
        end
        i
      rescue => e
        @stl&.error "Audiobook generation failed", exception: e
        nil
      end
    end
  end
end
