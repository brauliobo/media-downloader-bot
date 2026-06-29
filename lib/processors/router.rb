require_relative 'base'
require_relative 'document'
require_relative 'local_file'
require_relative 'srt'
require_relative 'url'
require_relative 'video'
require_relative 'audio'

module Processors
  class Router < Base

    def self.for_message(ctx, lines)
      url_lines = lines.select { |line| url_line?(line) }
      
      if url_lines.any?
        if url_lines.one?
          c = ctx.dup
          c.line = lines[lines.index(url_lines.first)..].join(' ')
          return [Url.new(c)]
        end

        return url_lines.map do |l|
          c = ctx.dup
          c.line = l
          Url.new(c)
        end
      end

      line = lines.join(' ')
      c = ctx.dup
      c.line = line

      return [Document.new(c)] if Document.can_handle?(c.msg)
      return [Srt.new(c)] if Srt.can_handle?(c)

      file = c.msg.video || c.msg.audio || c.msg.document
      return [LocalFile.new(c)] if file&.respond_to?(:local_path) && ::File.exist?(file.local_path)

      return [Video.new(c)] if c.msg.video.present?
      return [Audio.new(c)] if c.msg.audio.present?

      nil
    end

    def self.url_line?(line)
      line.to_s.split(/[[:space:]]+/).any? { |token| Utils::InputParser.url_like?(token) }
    end

  end
end
