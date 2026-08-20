require_relative '../../text_helpers'

module Audiobook
  module Parsers
    class Base
      DEFAULT_WORDS_PER_PAGE = 300
      BODY_FONT_SIZE         = 12
      HEADING_FONT_SIZE      = 20
      MAX_TEXT_BYTES         = ENV.fetch('MAX_STRUCTURED_DOCUMENT_BYTES', 20 * 1024 * 1024).to_i
      WINDOWS_CONTROLS       = {
        "\u0085" => '...', "\u0091" => "'", "\u0092" => "'",
        "\u0093" => '"', "\u0094" => '"', "\u0096" => '-', "\u0097" => '--'
      }.freeze

      def self.parse(path, stl: nil, opts: nil)
        data = extract_data(path, stl: stl, opts: opts)
        SymMash.new(data)
      end

      def self.extract_data(path, stl: nil, opts: nil)
        raise NotImplementedError, "Subclasses must implement extract_data"
      end

      def self.words_per_page(opts)
        wpp = (opts&.wpp || DEFAULT_WORDS_PER_PAGE).to_i
        wpp.positive? ? wpp : DEFAULT_WORDS_PER_PAGE
      end

      def self.paginate(lines, words_per_page = DEFAULT_WORDS_PER_PAGE)
        words_per_page = DEFAULT_WORDS_PER_PAGE unless words_per_page.to_i.positive?
        words = 0
        lines.each do |line|
          line.page = 1 + words / words_per_page
          words += line.text.to_s.split.size
        end
        lines.last&.page || 1
      end

      def self.line(text, font_size = BODY_FONT_SIZE, section_level: nil, language: nil, page: 1,
                    bold: nil, italic: nil, alignment: nil, color: nil, font_name: nil)
        text = normalize_plain_text(text)
        SymMash.new(
          text: text, font_size: font_size, section_level: section_level,
          language: language.to_s.strip.presence, y: nil, page: page,
          bold: bold, italic: italic, alignment: alignment, color: color, font_name: font_name
        ).compact unless text.empty?
      end

      def self.read_text(path, max_bytes: MAX_TEXT_BYTES)
        raise ArgumentError, 'document is too large' if File.size(path) > max_bytes

        raw = File.binread(path)
        return decode_utf16(raw, Encoding::UTF_16LE) if raw.start_with?("\xFF\xFE".b)
        return decode_utf16(raw, Encoding::UTF_16BE) if raw.start_with?("\xFE\xFF".b)

        utf8 = raw.dup.force_encoding(Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?

        raw.force_encoding(Encoding::Windows_1252).encode(Encoding::UTF_8)
      end

      def self.decode_utf16(raw, encoding)
        raw.byteslice(2..).force_encoding(encoding).encode(Encoding::UTF_8)
      end

      def self.normalize_plain_text(text)
        value = TextHelpers.normalize_text(text)
        WINDOWS_CONTROLS.each { |from, to| value.gsub!(from, to) }
        value.unicode_normalize(:nfc)
      end

      def self.paragraphs_from_plain_text(text)
        text = text.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
        blocks = if text.match?(/\n[ \t]*\n/)
          text.split(/\n[ \t]*\n+/)
        else
          text.split(/\n+/)
        end
        blocks.map { |block| normalize_plain_text(block.gsub(/\n+/, ' ')) }.reject(&:empty?)
      end
    end
  end
end
