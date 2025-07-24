require 'json'
require 'net/http'
require 'uri'
require 'tempfile'
require 'fileutils'

class TTS
  module CoquiTTS
    PORT = (ENV['PORT'] || 10230).to_i
    BASE_URL = "http://127.0.0.1:#{PORT}".freeze
    SYNTH_PATH = '/synthesize'.freeze

    def synthesize(text:, lang:, out_path:, speaker_wav: nil, **kwargs)
      uri = URI.join(BASE_URL, SYNTH_PATH)

      form_data = [['text', text], ['language', lang]]
      spk_wav = speaker_wav || ENV['SPEAKER_WAV']
      form_data << ['audio', File.open(spk_wav)] if spk_wav && !spk_wav.empty?
      kwargs.each { |k, v| form_data << [k.to_s, v.to_s] }

      req = Net::HTTP::Post.new(uri)
      req.set_form form_data, 'multipart/form-data'

      res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
      raise "TTS failed: #{res.code} – #{res.body}" unless res.is_a?(Net::HTTPSuccess)

      File.binwrite(out_path, res.body)
    ensure
      form_data&.each { |entry| entry[1].close if entry[0] == 'audio' && entry[1].respond_to?(:close) }
    end
  end

end
