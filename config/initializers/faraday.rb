require 'faraday/multipart'

Faraday::UploadIO = Faraday::Multipart::FilePart unless defined?(Faraday::UploadIO)
