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

      # Clean text to prevent punctuation from being spoken
      clean_text = clean_text_for_tts(text)
      
      form_data = [['text', clean_text], ['language', lang]]
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

    private

    def clean_text_for_tts(text)
      return text unless text

      # Remove or replace problematic punctuation that gets vocalized
      text = text.gsub(/\.{2,}/, '.')  # Replace multiple dots with single dot
      text = text.gsub(/[.!?]+$/, '')  # Remove ending punctuation
      text = text.gsub(/[,;:]/, ' ')   # Replace commas, semicolons, colons with spaces
      text = text.gsub(/["''""''`]/, '') # Remove quotes
      text = text.gsub(/[(){}\[\]]/, '')  # Remove brackets and parentheses
      text = text.gsub(/[-–—]/, ' ')     # Replace dashes with spaces
      text = text.gsub(/\s+/, ' ')       # Normalize whitespace
      text.strip
    end
  end

end
