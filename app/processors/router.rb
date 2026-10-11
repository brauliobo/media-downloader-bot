module Processors
  class Router < Base

    def self.for_message(ctx, lines)
      c = ctx.dup
      return file_processors(c, lines) if Utils::InputParser.attached_file?(c.msg)

      url_inputs = Utils::InputParser.url_inputs(lines)
      if url_inputs.any?
        return url_inputs.map do |input|
          u = ctx.dup
          u.line = input
          Url.new(u)
        end
      end

      nil
    end

    def self.file_processors(ctx, lines)
      ctx.line = Utils::InputParser.option_line(lines)

      return [Document.new(ctx)] if Document.can_handle?(ctx.msg)
      return [Srt.new(ctx)] if Srt.can_handle?(ctx)

      file = ctx.msg.video || ctx.msg.audio || ctx.msg.document
      return [LocalFile.new(ctx)] if file&.respond_to?(:local_path) && ::File.exist?(file.local_path)
      return [Video.new(ctx)] if ctx.msg.video.present?
      return [Audio.new(ctx)] if ctx.msg.audio.present?

      nil
    end
    private_class_method :file_processors

  end
end
