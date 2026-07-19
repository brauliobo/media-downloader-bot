require 'rack/mime'

Rack::Mime::MIME_TYPES['.opus'] = 'audio/ogg'
Rack::Mime::MIME_TYPES['.flac'] = 'audio/x-flac'
Rack::Mime::MIME_TYPES['.caf']  = 'audio/x-caf'
Rack::Mime::MIME_TYPES['.aac']  = 'audio/x-aac'
Rack::Mime::MIME_TYPES['.mkv']  = 'video/x-matroska'

module Utils
  module MimeTypes
    module_function

    def telegram_type(mime)
      case mime.to_s
      when /\Aaudio\// then :audio
      when /\Aimage\// then :photo
      when /\Avideo\// then :video
      else :document
      end
    end
  end
end
