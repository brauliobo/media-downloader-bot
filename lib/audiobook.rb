require 'addressable/uri'
require 'tmpdir'
require 'fileutils'
require 'set'
require 'yaml'

require_relative 'ocr'
require_relative 'tts'
require_relative 'zipper'
require_relative 'utils/sh'
require_relative 'translator'
require_relative 'audiobook/source_formats'
require_relative 'audiobook/book'
require_relative 'audiobook/chapter'
require_relative 'audiobook/pauses'
require_relative 'audiobook/section'
require_relative 'audiobook/runner'
require_relative 'audiobook/yaml'
require_relative 'audiobook/text_pdf'

module Audiobook
  def self.generate(input_path, out_audio, stl: nil, opts: nil)
    unless input_path.to_s =~ /\Ahttps?:/i
      raise "Input not found: #{input_path}" unless File.exist?(input_path)
    end

    opts ||= SymMash.new
    opts.source_base ||= base_from_source(input_path)
    book = Audiobook::Book.from_input(input_path, opts: opts, stl: stl, translate: opts.onlyyml)
    yaml_path = SourceFormats.yaml_path(input_path, out_audio)
    audio = Runner.new(book, stl, opts).process_to_audio(out_audio) unless opts.onlyyml
    book.write(yaml_path)
    SymMash.new(
      yaml: yaml_path, audio: audio, book: book,
      pdf: book.metadata['kindle_pdf'] || book.metadata[:kindle_pdf],
      translation_pdf: write_translation_pdf(book, input_path, yaml_path, stl)
    )
  end

  # Unified helper to generate audiobook and return ready-to-upload entries
  def self.generate_uploads(source, dir:, stl:, opts: SymMash.new)
    base = base_from_source(source)
    audio_format = Zipper::Types.audio.aac
    audio_out = File.join(dir, "#{base}.#{audio_format.ext}")
    result = generate(source, audio_out, stl: stl, opts: opts)
    title  = upload_title(result.book, base)
    result = relocate_translated_outputs(result, title) if result.book.is_a?(Book) && result.book.translated
    uploads = [document_upload(result.yaml, title, 'application/x-yaml')]
    return uploads if opts.onlyyml

    uploads << document_upload(result.translation_pdf, title, 'application/pdf') if result.translation_pdf
    uploads << audio_upload(result, dir, base, audio_format, title: title)
    uploads
  ensure
    cleanup_kindle_capture(result&.pdf)
  end

  def self.document_upload(path, title, mime)
    upload(path, type: :document, title: title, mime: mime)
  end

  def self.audio_upload(result, dir, base, audio_format, title: base)
    upload = upload(
      result.audio, type: :audio, title: title, mime: audio_format.mime,
      uploader: upload_author(result.book).to_s, format: audio_format,
      thumb: result.book.thumb(dir: dir, base: base)
    )
    upload.oprobe = Prober.for(result.audio)
    upload
  rescue => e
    STDERR.puts "[AUDIOBOOK] probe failed: #{e.class}: #{e.message}"
    upload
  end

  def self.upload(path, type:, title:, mime:, uploader: '', format: nil, **extra)
    SymMash.new(
      fn_out: path,
      type:   SymMash.new(name: type),
      info:   SymMash.new(title: title, uploader: uploader),
      mime:   mime,
      opts:   SymMash.new(format: format || SymMash.new(mime: mime)),
      **extra
    )
  end

  def self.write_translation_pdf(book, input_path, yaml_path, stl)
    return unless book.translated
    return unless SourceFormats.format_for_path(input_path)&.[](:parser) == :parse_pdf

    TextPdf.generate(book, yaml_path.sub(/\.yml\z/i, ".#{book_language(book)}.pdf"), stl: stl, source_pdf: input_path)
  end

  def self.processing_status(*parts, ocr: false)
    line = "Processing #{parts.compact.join(', ')}"
    line += " (OCR)" if ocr
    line
  end

  def self.upload_title(book, fallback)
    return fallback unless book
    return book.title.presence || book.translated_base.presence || fallback if book.is_a?(Book)

    meta(book, :title) || fallback
  end

  def self.upload_author(book)
    (book.author if book.is_a?(Book)).presence || meta(book, :author)
  end

  def self.meta(book, key)
    md = book.metadata if book.respond_to?(:metadata)
    md[key].presence || md[key.to_s].presence if md
  end

  def self.book_language(book)
    return book.language if book.is_a?(Book)

    meta(book, :language) || 'en'
  end

  def self.relocate_translated_outputs(result, title)
    base = safe_filename(title)
    return result unless base.present?

    lang = book_language(result.book)
    result.yaml            = relocate_file(result.yaml, "#{base}.yml")
    result.translation_pdf = relocate_file(result.translation_pdf, "#{base}.#{lang}.pdf") if result.translation_pdf
    result.audio           = relocate_file(result.audio, "#{base}#{File.extname(result.audio.to_s)}") if result.audio
    result
  end

  def self.relocate_file(path, name)
    return path unless path && File.file?(path)

    dest = File.join(File.dirname(path), name)
    File.rename(path, dest) unless dest == path
    dest
  end

  def self.safe_filename(name)
    name.to_s.gsub(/[\/\\\0]/, ' ').gsub(/\s+/, ' ').strip.sub(/\.\z/, '').presence
  end

  def self.cleanup_kindle_capture(pdf_path)
    return unless pdf_path && File.file?(pdf_path)

    capture_dir = File.realpath(File.dirname(pdf_path))
    tmp_root    = File.realpath(Dir.tmpdir)
    return unless File.basename(capture_dir).start_with?('kindle_shots_')
    return unless capture_dir.start_with?("#{tmp_root}#{File::SEPARATOR}")

    FileUtils.remove_entry_secure(capture_dir)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def self.base_from_source(source)
    if File.exist?(source.to_s)
      File.basename(source, File.extname(source))
    else
      begin
        uri = Addressable::URI.parse(source.to_s)
        qv  = uri.query_values || {}
        qv['asin'].presence || 'audiobook'
      rescue
        'audiobook'
      end
    end
  end

end
