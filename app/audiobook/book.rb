require 'json'
require 'yaml'
require 'set'
require 'fileutils'
require 'uri'
require 'date'

module Audiobook
  # Represents an intermediate structured manuscript that can be saved as YAML.
  class Book
    attr_reader :data, :metadata, :pages, :translated, :translated_base, :author_gender, :font_roles

    def title    = field(:title)
    def author   = field(:author)
    def language = (@lang.presence || field(:language) || 'en').to_s

    # Alias for backward compatibility
    def items
      pages.flat_map(&:items)
    end

    def self.from_input(input_path, opts: nil, stl: nil, translate: true)
      return new(data: Source.parse_kindle(input_path, opts: opts, stl: stl), opts: opts, stl: stl, translate: translate) if Source.kindle?(input_path)

      format = SourceFormats.format_for_path(input_path)
      return from_yaml(input_path, opts: opts, stl: stl, translate: translate) if format&.dig(:loader) == :yaml

      new(data: Source.parse(input_path, format, opts: opts, stl: stl), opts: opts, stl: stl, translate: translate)
    end

    # The language of the document, from the options or else from what its first pages say.
    def self.detect_language(input_path, opts: nil, stl: nil)
      lang = Languages.source(opts)
      return lang if lang

      opts ||= SymMash.new
      format = SourceFormats.format_for_path(input_path)
      data = format&.dig(:loader) == :yaml ? SymMash.new(Yaml.load(input_path)) : Source.parse(input_path, format, opts: opts, stl: stl)
      metadata = data.metadata || SymMash.new
      sample = Publication.sample_from_data(data, opts: opts, stl: stl)
      unless opts.html_title.present? || sample.blank?
        Publication.detect!(metadata, sample: sample, filename: Publication.filename(metadata, opts), stl: stl)
      end
      metadata.language || 'en'
    end

    def self.translate_sentences(sentences, from:, to:)
      sentences.group_by { |sent| sent.language.presence || from }.each do |source, group|
        texts = Array(Translator.translate(group.map(&:text), from: source, to: to))
        group.zip(texts).each do |sent, text|
          sent.text     = text
          sent.language = to
        end
      end
    end

    # A book already assembled, as written by #write.
    def self.from_yaml(yaml_path, opts: nil, stl: nil, translate: true)
      data = SymMash.new(Yaml.load(yaml_path))
      # Support both new format (no metadata) and legacy format (with metadata)
      metadata = data.metadata || SymMash.new
      metadata.language ||= data.language
      metadata.language ||= Languages.source(opts)

      new(pages: Yaml.pages(data), metadata: metadata, font_roles: (FontRoles.from_h(data.font_roles) if data.font_roles),
          opts: opts, stl: stl, translate: translate)
    end

    # Either a parsed document to assemble pages from, or the pages themselves.
    def initialize(data: nil, pages: nil, metadata: nil, font_roles: nil, opts: nil, stl: nil, translate: true)
      @data = data
      @metadata = metadata || @data&.metadata || SymMash.new
      @opts = opts || SymMash.new
      @stl = stl

      if pages
        @pages, @font_roles = pages, font_roles
        @lang = @metadata.language || 'en'
      else
        @metadata.language ||= Languages.source(@opts)
        detect_publication!
        @lang = @metadata.language || 'en'
        # Handle new line-based format or legacy paragraph format
        @pages = @data.content&.lines ? pages_from_lines(@data.content.lines, @data.content.images || []) : ParagraphPages.build(@data, stl: @stl)
      end

      finish_pages!(translate: translate)
    end

    # Write YAML file following class hierarchy representation
    def write(yaml_path) = Yaml.write(self, yaml_path)

    def outline = Outline.build(pages)

    def thumb(dir:, base:)
      cover_for_thumb&.thumbnail(dir: dir, base: base)
    end

    def speech_language = Languages.speech(@opts)

    def translation_needed?
      (target = speech_language) && target != @lang.to_s
    end

    def mark_translated!(target)
      @lang = @metadata.language = target
      @translated = true
    end

    def translate!
      target = speech_language
      pending = @pages.flat_map(&:all_sentences).reject { |sent| sent.language.to_s == target.to_s }
      if pending.any?
        @stl&.update 'Translating pages'
        self.class.translate_sentences(pending, from: @lang, to: target)
      end
      translate_names!(from: @lang, to: target)
      mark_translated!(target)
    end

    def translate_names!(from:, to:)
      names = [title, author, @opts&.source_base.presence].compact.uniq
      return if names.empty?

      @stl&.update 'Translating title'
      names.zip(Array(Translator.translate(names, from: from, to: to))).each do |orig, text|
        apply_translated_name(orig, text)
      end
    end

    def apply_translated_name(orig, text)
      text = text.to_s.gsub(/[\/\\\0]/, ' ').gsub(/\s+/, ' ').strip.presence || orig
      @metadata.title    = text if orig == title
      @metadata.author   = text if orig == author
      @translated_base   = text if @opts&.source_base.to_s == orig
    end

    private

    def detect_publication!
      return if @publication_detected

      @publication_detected = true
      return @author_gender ||= 'male' if @opts.html_title.present?

      sample = publication_sample
      return if sample.blank?

      @author_gender = Publication.detect!(@metadata, sample: sample, filename: Publication.filename(@metadata, @opts), stl: @stl)
    end

    def publication_sample
      @pages ? Publication.sample_from_pages(@pages) : Publication.sample_from_data(@data, opts: @opts, stl: @stl)
    end

    def cover_for_thumb
      metadata.cover.presence || cover_from_source
    end

    def cover_from_source
      path = field(:source_path)
      return unless path && File.file?(path.to_s)

      Cover.from_page(path, SymMash.new(number: 1, width: field(:page_width).to_f, height: field(:page_height).to_f))
    end

    # Build pages from Line objects (new format with font metadata)
    def pages_from_lines(lines_data, images_data = [])
      @from_lines = true
      assembly    = Assembly.new(metadata: @metadata, opts: @opts, stl: @stl, lang: @lang,
                                 include_all: include_all?)
      assembly.pages(lines_data, images_data).tap { @font_roles = assembly.font_roles }
    end

    def include_all?
      !!(@opts&.includeall || @data&.opts&.includeall || translation_needed?)
    end

    def finish_pages!(translate: true)
      select_pages!
      PageBoundaries.strip!(pages) unless include_all? || @from_lines
      detect_publication!
      translate! if translate && translation_needed?
    end

    def select_pages!
      selected_pages = PageSelection.parse(@opts&.pages)
      return unless selected_pages

      available_pages = pages.map(&:number)
      missing_pages   = selected_pages - available_pages
      raise ArgumentError, "pages not found: #{missing_pages.join(', ')}" if missing_pages.any?

      @pages = pages.select { |page| selected_pages.include?(page.number) }
    end

    def field(key) = Publication.field(metadata, key)
  end
end
