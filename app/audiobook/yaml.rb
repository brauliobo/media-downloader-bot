require 'addressable/uri'
require 'date'
require 'yaml'

module Audiobook
  class Yaml
    def self.generate_audio(yaml_path, dir:, stl:, opts: SymMash.new)
      raise "YAML file not found: #{yaml_path}" unless File.exist?(yaml_path)
      
      book = Book.from_yaml(yaml_path, opts: opts, stl: stl)
      base = Audiobook.base_from_source(yaml_path)
      audio_out = File.join(dir, "#{base}.opus")
      
      final_audio = Runner.new(book, stl, opts).process_to_audio(audio_out)
      raise 'Failed to generate audiobook' unless File.exist?(final_audio)
      
      [
        SymMash.new(
          fn_out: final_audio,
          type: SymMash.new(name: :audio),
          info: SymMash.new(title: base, uploader: ''),
          mime: 'audio/ogg',
          opts: SymMash.new(format: SymMash.new(mime: 'audio/ogg')),
          oprobe: Prober.for(final_audio)
        )
      ]
    end

    MAX_BYTES = ENV.fetch('MAX_STRUCTURED_DOCUMENT_BYTES', 20 * 1024 * 1024).to_i

    def self.read_structured(path)
      raise ArgumentError, 'structured document is too large' if File.size(path) > MAX_BYTES

      File.binread(path)
    end

    def self.load(path)
      YAML.safe_load(read_structured(path), permitted_classes: [Date, Time], aliases: false) || {}
    end

    # The pages of a book written as YAML: the current shape, or the legacy one with a single list of items.
    def self.pages(data)
      return [Page.new(1, parse_items(data.items))] unless data.pages

      data.pages.map do |page_data|
        page_info = (page_data.is_a?(Hash) ? SymMash.new(page_data) : page_data).page || SymMash.new
        Page.new(page_info.number || 0, parse_items(page_info.items))
      end
    end

    def self.parse_items(items)
      (items || []).map { |item| parse_item(item.is_a?(Hash) ? SymMash.new(item) : item) }.compact
    end

    def self.write(book, path)
      hash = { 'language' => book.language, 'pages' => book.pages.map(&:to_h) }
      hash['font_roles'] = book.font_roles.to_h if book.font_roles
      outline = book.outline
      hash['outline'] = outline if outline.any?
      hash = plain(hash)
      begin
        File.write(path, YAML.dump(hash, line_width: -1))
      rescue ArgumentError
        File.write(path, YAML.dump(hash))
      end
    end

    # One item of a page: a hash with a single key naming its kind, or the legacy shape with a type field.
    def self.parse_item(item)
      item = SymMash.wrap(item)
      if item.heading      then heading(item.heading)
      elsif item.section   then section(item.section)
      elsif item.reference then reference(item.reference)
      elsif item.image     then Image.new(item.image.path || '', sentences: Sentence.build_all(item.image.sentences))
      elsif item.paragraph then paragraph(item.paragraph)
      else legacy_item(item)
      end
    end

    def self.heading(data)
      apply_style(Heading.new(data.text, language: data.language), data) if Sentence.speakable_text?(data.text)
    end

    def self.section(data)
      return unless Sentence.speakable_text?(data.text)

      apply_style(Section.new(data.text, level: data.level || 1, language: data.language), data)
    end

    def self.reference(data) = Reference.new(data.id, Sentence.build_all(data.sentences))

    def self.paragraph(data)
      sentences = (data.sentences || []).filter_map do |sentence|
        sentence = SymMash.wrap(sentence)
        Sentence.build(sentence)&.tap do |built|
          built.references = sentence.references.map { |ref| reference(SymMash.wrap(ref.reference || ref)) } if sentence.references
        end
      end
      Paragraph.new(sentences) unless sentences.empty?
    end

    def self.legacy_item(item)
      case item.type
      when 'Heading' then Heading.new(item.text, language: item.language)
      when 'Image'   then Image.new(item.path || '', sentences: Sentence.build_all(item.sentences))
      else
        sentences = Sentence.build_all(item.sentences)
        Paragraph.new(sentences) unless sentences.empty?
      end
    end

    def self.apply_style(item, data)
      FontRoles.copy_style(item, data) if item && data
      item.role = data.role.to_s.to_sym if item && data.role
      item
    end

    def self.plain(obj)
      case obj
      when SymMash
        obj.to_h.transform_values { |v| plain(v) }
      when Hash
        obj.transform_values { |v| plain(v) }
      when Array
        obj.map { |v| plain(v) }
      else
        obj
      end
    end
  end
end

