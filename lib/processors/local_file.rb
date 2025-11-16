require_relative 'media'

module Processors
  class LocalFile < Media

    def self.attach_to_message(msg, file_path, opts: [])
      return unless ::File.exist?(file_path)

      ext = ::File.extname(file_path).downcase
      mime = Rack::Mime.mime_type(ext)
      file_info = SymMash.new(file_name: ::File.basename(file_path), mime_type: mime, local_path: ::File.expand_path(file_path))

      if mime&.match?(/^video\//)
        msg.video = file_info
      elsif mime&.match?(/^audio\//)
        msg.audio = file_info
      else
        msg.document = file_info
      end
      msg.text = opts.join(' ') if opts.any?
      msg
    end

    def initialize(**params)
      super(**params)
      self.attr = :video if msg.video&.respond_to?(:local_path)
      self.attr = :audio if msg.audio&.respond_to?(:local_path)
      self.attr ||= :document
    end

  end
end

