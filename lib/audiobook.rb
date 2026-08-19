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
    book = Audiobook::Book.from_input(input_path, opts: opts, stl: stl, translate: opts.onlyyml)
    yaml_path = SourceFormats.yaml_path(input_path, out_audio)
    pdf_path = book.metadata['kindle_pdf'] || book.metadata[:kindle_pdf]

    if opts.onlyyml
      book.write(yaml_path)
      return SymMash.new(yaml: yaml_path, pdf: pdf_path, translation_pdf: write_translation_pdf(book, input_path, yaml_path, stl), book: book)
    end

    final_audio = Runner.new(book, stl, opts).process_to_audio(out_audio)
    book.write(yaml_path)
    SymMash.new(yaml: yaml_path, audio: final_audio, pdf: pdf_path, translation_pdf: write_translation_pdf(book, input_path, yaml_path, stl), book: book)
  end

  # Unified helper to generate audiobook and return ready-to-upload entries
  def self.generate_uploads(source, dir:, stl:, opts: SymMash.new)
    base = base_from_source(source)
    audio_format = Zipper::Types.audio.aac
    audio_out = File.join(dir, "#{base}.#{audio_format.ext}")
    result = generate(source, audio_out, stl: stl, opts: opts)
    uploads = [document_upload(result.yaml, base, 'application/x-yaml')]
    return uploads if opts.onlyyml

    uploads << document_upload(result.translation_pdf, base, 'application/pdf') if result.translation_pdf
    uploads << audio_upload(result, dir, base, audio_format)
    uploads
  ensure
    cleanup_kindle_capture(result&.pdf)
  end

  def self.document_upload(path, base, mime)
    SymMash.new(
      fn_out: path,
      type:   SymMash.new(name: :document),
      info:   SymMash.new(title: base, uploader: ''),
      mime:   mime,
      opts:   SymMash.new(format: SymMash.new(mime: mime))
    )
  end

  def self.audio_upload(result, dir, base, audio_format)
    upload = SymMash.new(
      fn_out: result.audio,
      type:   SymMash.new(name: :audio),
      info:   SymMash.new(title: base, uploader: ''),
      thumb:  result.book.thumb(dir: dir, base: base),
      mime:   audio_format.mime,
      opts:   SymMash.new(format: audio_format)
    )
    upload.oprobe = Prober.for(result.audio)
    upload
  rescue => e
    STDERR.puts "[AUDIOBOOK] probe failed: #{e.class}: #{e.message}"
    upload
  end

  def self.write_translation_pdf(book, input_path, yaml_path, stl)
    return unless book.translated
    return unless SourceFormats.format_for_path(input_path)&.[](:parser) == :parse_pdf

    lang = book.metadata['language'] || book.metadata[:language]
    TextPdf.generate(book, yaml_path.sub(/\.yml\z/i, ".#{lang}.pdf"), stl: stl)
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
