require 'json'

require_relative '../utils/http'
require_relative '../zipper'

class Diarizer
  module HTTPBackend
    module_function

    def diarize(api, path, speakers: nil)
      wav  = Zipper.audio_to_wav(path, sample_rate: 16_000, channels: 1)
      file = File.open(wav)
      params = {file: file}
      params[:speakers] = speakers.to_i.to_s if speakers.to_i.positive?
      response = Utils::HTTP.post("#{api.to_s.delete_suffix('/')}/v1/diarize", params)
      raise "diarization failed: #{response.code}" unless response.code == '200'

      output = SymMash.new(JSON.parse(response.body))
      validate!(output.segments)
      output
    ensure
      file&.close
      File.unlink(wav) if wav && File.exist?(wav)
    end

    def validate!(segments)
      valid = Array(segments).all? do |segment|
        start  = segment[:start]
        finish = segment[:end]
        start.is_a?(Numeric) && start.finite? &&
          finish.is_a?(Numeric) && finish.finite? && finish > start &&
          segment[:speaker_id].present?
      end
      raise 'diarization returned malformed speaker segments' unless valid
    end
  end
end
