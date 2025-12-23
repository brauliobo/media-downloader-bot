require_relative 'base'
require_relative 'document'
require_relative 'local_file'
require_relative 'url'
require_relative 'video'
require_relative 'audio'

module Processors
  class Router < Base

    def self.for_message(ctx, lines)
      url_lines = lines.select { |l| l =~ URI::DEFAULT_PARSER.make_regexp }
      
      if url_lines.any?
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

      file = c.msg.video || c.msg.audio || c.msg.document
      return [LocalFile.new(c)] if file&.respond_to?(:local_path) && ::File.exist?(file.local_path)

      return [Video.new(c)] if c.msg.video.present?
      return [Audio.new(c)] if c.msg.audio.present?

      nil
    end

  end
end
