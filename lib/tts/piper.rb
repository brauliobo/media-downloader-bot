# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'tempfile'
require 'fileutils'

# Text-to-speech backend that talks to running Piper HTTP servers
class TTS
  module Piper
    # Map ISO language codes to Piper HTTP server ports
    PORT_MAP = {
      'pt' => ENV['PIPER_PORT_PT'],
      'en' => ENV['PIPER_PORT_EN'],
    }.freeze

    ENDPOINT_TEMPLATE = 'http://127.0.0.1:%<port>d'.freeze

    def synthesize(text:, lang:, out_path:, voice: nil, **kwargs)
      port = PORT_MAP[lang] or raise ArgumentError, "Unsupported language: #{lang}"
      uri = URI.parse(format(ENDPOINT_TEMPLATE, port: port))
      # Ensure text is properly encoded as UTF-8
      clean_text = text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      payload = { text: clean_text }
      payload[:voice] = voice if voice
      payload.merge!(kwargs)

      res = Net::HTTP.post(uri, payload.to_json, 'Content-Type' => 'application/json')
      raise "TTS failed: #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      File.binwrite(out_path, res.body)
      out_path
    end
  end
end 