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
      type = value(upload, :type)
      type = type.name if type.respond_to?(:name)

      type_for(value(upload, :mime), type)
    end

    # A downloader knows the MIME type before it has an upload to describe.
    def type_for_mime(mime) = type_for(mime, nil)

    def type_for(mime, type)
      return :audio if mime.to_s.match?(/\Aaudio\//)
      return :photo if mime.to_s.match?(/\Aimage\//)
      return :video if mime.to_s.match?(/\Avideo\//)
      return type.to_sym if %i[audio photo video document].include?(type.to_s.to_sym)

      :document
    end

    def album_item?(upload)
      %i[photo video].include?(telegram_type(upload)) && File.file?(value(upload, :fn_out).to_s)
    end

    # An upload is a SymMash, which symbolizes its keys.
    def value(object, key) = object[key]
  end
end
