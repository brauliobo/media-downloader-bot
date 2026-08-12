require_relative 'file'

module Processors
  class Document < File
    MAX_BYTES = ENV.fetch('MAX_DOCUMENT_BYTES', 200 * 1024 * 1024).to_i
    AUDIOBOOK_KINDS = {
      pdf:  { exts: %w[.pdf], mimes: %w[application/pdf] },
      epub: { exts: %w[.epub], mimes: %w[application/epub+zip] },
      yaml: { exts: %w[.yml .yaml], mimes: %w[application/x-yaml] },
      txt:  { exts: %w[.txt], mimes: %w[text/plain] },
    }.freeze

    self.attr = :document

    def self.document_kind(doc_or_msg)
      doc = doc_or_msg.respond_to?(:document) ? doc_or_msg.document : doc_or_msg
      return unless doc

      fname = doc.file_name.to_s.downcase
      mime  = doc.mime_type.to_s
      AUDIOBOOK_KINDS.each do |kind, spec|
        return kind if spec[:mimes].include?(mime) || spec[:exts].any? { |ext| fname.end_with?(ext) }
      end
      nil
    end

    def self.pdf_document?(doc_or_msg)  = document_kind(doc_or_msg) == :pdf
    def self.epub_document?(doc_or_msg) = document_kind(doc_or_msg) == :epub
    def self.yaml_document?(doc_or_msg) = document_kind(doc_or_msg) == :yaml
    def self.txt_document?(doc_or_msg)  = document_kind(doc_or_msg) == :txt
    def self.can_handle?(msg)           = !!document_kind(msg)

    def document_kind   = self.class.document_kind(msg)
    def pdf_document?   = document_kind == :pdf
    def epub_document?  = document_kind == :epub
    def yaml_document?  = document_kind == :yaml
    def txt_document?   = document_kind == :txt

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
