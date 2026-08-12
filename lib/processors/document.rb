require_relative 'file'
require_relative '../audiobook/source_formats'

module Processors
  class Document < File
    MAX_BYTES = ENV.fetch('MAX_DOCUMENT_BYTES', 200 * 1024 * 1024).to_i

    self.attr = :document

    def self.document_kind(doc_or_msg)
      doc = doc_or_msg.respond_to?(:document) ? doc_or_msg.document : doc_or_msg
      return unless doc

      Audiobook::SourceFormats.document_kind(file_name: doc.file_name, mime_type: doc.mime_type)
    end

    def self.can_handle?(msg) = !!document_kind(msg)

    def document_kind = self.class.document_kind(msg)

    def download
      info = msg.document
      size = info.file_size if info&.respond_to?(:file_size)
      raise ArgumentError, 'document is too large' if size.to_i > MAX_BYTES

      input = super
      raise ArgumentError, 'document is too large' if input&.fn_in && ::File.size(input.fn_in) > MAX_BYTES
      input
    end

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
