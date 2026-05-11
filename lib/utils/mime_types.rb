require 'rack/mime'

Rack::Mime::MIME_TYPES['.opus'] = 'audio/ogg'
Rack::Mime::MIME_TYPES['.flac'] = 'audio/x-flac'
Rack::Mime::MIME_TYPES['.caf']  = 'audio/x-caf'
Rack::Mime::MIME_TYPES['.aac']  = 'audio/x-aac'
Rack::Mime::MIME_TYPES['.mkv']  = 'video/x-matroska'
