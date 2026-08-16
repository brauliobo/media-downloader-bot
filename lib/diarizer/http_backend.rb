require 'json'

require_relative 'result'
require_relative '../utils/http'
require_relative '../zipper'

class Diarizer
  module HTTPBackend
    module_function

    def diarize(api, path, speakers: nil)
      Zipper.with_audio_wav(path, sample_rate: 16_000, channels: 1) do |file|
        params = {file: file}
        params[:speakers] = speakers.to_i.to_s if speakers.to_i.positive?
        response = Utils::HTTP.post("#{api.to_s.delete_suffix('/')}/v1/diarize", params)
        raise "diarization failed: #{response.code}" unless response.code == '200'

        Result.from_json(response.body)
      end
    end
  end
end
