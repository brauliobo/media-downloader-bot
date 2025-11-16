require_relative 'base'
require_relative 'document'
require_relative 'local_file'
require_relative 'url'
require_relative 'video'
require_relative 'audio'

module Processors
  class Router < Base

    def self.for_message(msg, lines, **popts)
      url_lines = lines.select { |l| l =~ URI::DEFAULT_PARSER.make_regexp }
      return url_lines.map { |l| Url.new line: l, **popts } if url_lines.any?

      line = lines.join(' ')

      return [Document.new(line: line, **popts)] if Document.can_handle?(msg)

      file = msg.video || msg.audio || msg.document
      return [LocalFile.new(line: line, **popts)] if file&.respond_to?(:local_path) && ::File.exist?(file.local_path)

      return [Video.new(line: line, **popts)] if msg.video.present?
      return [Audio.new(line: line, **popts)] if msg.audio.present?

      nil
    end

  end
end