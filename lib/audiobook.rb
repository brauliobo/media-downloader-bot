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
require_relative 'audiobook/book'
require_relative 'audiobook/runner'
require_relative 'audiobook/yaml'
require_relative 'audiobook/text_pdf'

module Audiobook
  def self.generate(input_path, out_audio, stl: nil, opts: nil)
    unless input_path.to_s =~ /\Ahttps?:/i
      raise "Input not found: #{input_path}" unless File.exist?(input_path)
    end

    opts ||= SymMash.new
    book = Audiobook::Book.from_input(input_path, opts: opts, stl: stl)

    yaml_path = input_path.sub(/\.(pdf|epub|json)$/i, '.yml')
    yaml_path = input_path if input_path =~ /\.(yml|yaml)$/i
    yaml_path = File.join(File.dirname(out_audio), "#{File.basename(out_audio, File.extname(out_audio))}.yml") if yaml_path == input_path

    book.write(yaml_path)

    return SymMash.new(yaml: yaml_path) if opts.onlyyml

    final_audio = Runner.new(book, stl, opts).process_to_audio(out_audio)
    # If Book came from Kindle capture, it may carry the compiled PDF path in metadata
    pdf_path = book.metadata['kindle_pdf'] || book.metadata[:kindle_pdf]
    SymMash.new(yaml: yaml_path, audio: final_audio, pdf: pdf_path)
  end

  # Unified helper to generate audiobook and return ready-to-upload entries
  def self.generate_uploads(source, dir:, stl:, opts: SymMash.new)
    base = base_from_source(source)
    audio_out = File.join(dir, "#{base}.opus")
    result = generate(source, audio_out, stl: stl, opts: opts)

    book = Audiobook::Book.from_input(source, opts: opts, stl: stl)
    thumbnail_path = book.thumb(dir: dir, base: base)

    uploads = [
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
        info: SymMash.new(title: base, uploader: '', thumbnail: thumbnail_path),
        mime: 'audio/ogg',
        opts: SymMash.new(format: SymMash.new(mime: 'audio/ogg'))
      )
    ]

    begin
      uploads[1].oprobe = Prober.for(result.audio)
    rescue => e
      # Probe failed - upload_one will probe if needed
    end

    uploads
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