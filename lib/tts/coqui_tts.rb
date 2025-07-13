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

    # Synthesise speech via the Flask Coqui-TTS server.
    #
    # Required parameters:
    #   text        – text to speak
    #   lang        – ISO language code expected by the model (e.g. 'en', 'pt')
    #   out_path    – where to write the resulting WAV
    #   speaker_wav – path to reference speaker WAV for cloning (optional)
    #
    # Pass `speaker_wav:` or set ENV['SPEAKER_WAV'] globally.
    def synthesize(text:, lang:, out_path:, speaker_wav: nil, **kwargs)

      uri = URI.join(BASE_URL, SYNTH_PATH)

      # Build multipart form data. Attach speaker reference only if provided.
      form_data = [['text', text], ['language', lang]]
      spk_wav = speaker_wav || ENV['SPEAKER_WAV']
      form_data << ['audio', File.open(spk_wav)] if spk_wav && !spk_wav.empty?
      kwargs.each { |k, v| form_data << [k.to_s, v.to_s] }

      req = Net::HTTP::Post.new(uri)
      req.set_form form_data, 'multipart/form-data'

      res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
      raise "TTS failed: #{res.code} – #{res.body}" unless res.is_a?(Net::HTTPSuccess)

      File.binwrite(out_path, res.body)
      out_path
    ensure
      # Ensure file handle is closed when set_form opened it
      form_data&.each do |entry|
        entry[1].close if entry[0] == 'audio' && entry[1].respond_to?(:close)
      end
    end
  end

end
