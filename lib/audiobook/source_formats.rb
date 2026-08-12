module Audiobook
  module SourceFormats
    FORMATS = {
      yaml: { extensions: %w[.yml .yaml], mimes: %w[application/x-yaml], loader: :yaml, document: true },
      json: { extensions: %w[.json], parser: :parse_json },
      pdf:  { extensions: %w[.pdf], mimes: %w[application/pdf], parser: :parse_pdf, document: true },
      epub: { extensions: %w[.epub], mimes: %w[application/epub+zip], parser: :parse_epub, document: true },
      html: { extensions: %w[.html .htm], parser: :parse_html },
      txt:  {
        extensions: %w[.txt], mimes: %w[text/plain], parser: :parse_txt,
        document: true, mime_requires_unnamed: true,
      },
    }.transform_values(&:freeze).freeze

    module_function

    def format_for_path(path)
      entry_for_extension(File.extname(path.to_s))&.last
    end

    def entry_for_extension(extension)
      extension = extension.to_s.downcase
      FORMATS.find { |_kind, format| format[:extensions].include?(extension) }
    end

    def document_kind(file_name:, mime_type: nil)
      named = !file_name.to_s.empty?
      extension_entry = entry_for_extension(File.extname(file_name.to_s)) if named
      return extension_entry.first if extension_entry&.last&.dig(:document)

      FORMATS.find do |_kind, format|
        format[:document] && format.fetch(:mimes, []).include?(mime_type.to_s) &&
          (!named || !format[:mime_requires_unnamed])
      end&.first
    end

    def yaml_path(input_path, out_audio)
      format = format_for_path(input_path)
      return output_yaml_path(out_audio) if format.nil? || format[:loader] == :yaml

      input_path.sub(/#{Regexp.escape(File.extname(input_path))}\z/i, '.yml')
    end

    def output_yaml_path(out_audio)
      File.join(File.dirname(out_audio), "#{File.basename(out_audio, File.extname(out_audio))}.yml")
    end
  end
end
