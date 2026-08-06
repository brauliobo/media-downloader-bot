require 'rack/mime'

Rack::Mime::MIME_TYPES['.opus'] = 'audio/ogg'
Rack::Mime::MIME_TYPES['.flac'] = 'audio/x-flac'
Rack::Mime::MIME_TYPES['.caf']  = 'audio/x-caf'
Rack::Mime::MIME_TYPES['.aac']  = 'audio/x-aac'
Rack::Mime::MIME_TYPES['.mkv']  = 'video/x-matroska'

module Utils
  module MimeTypes
    module_function

    def telegram_type(upload)
      mime = value(upload, :mime) || upload
      type = value(upload, :type)
      type = type.name if type.respond_to?(:name)

      return :audio if mime.to_s.match?(/\Aaudio\//)
      return :photo if mime.to_s.match?(/\Aimage\//)
      return :video if mime.to_s.match?(/\Avideo\//)
      return type.to_sym if %i[audio photo video document].include?(type.to_s.to_sym)

      :document
    end

    def album_item?(upload)
      %i[photo video].include?(telegram_type(upload)) && File.file?(value(upload, :fn_out).to_s)
    end

    def value(object, key)
      return object[key] || object[key.to_s] if object.is_a?(Hash)
      return object.public_send(key) if object.respond_to?(key)

      nil
    end
  end
end
