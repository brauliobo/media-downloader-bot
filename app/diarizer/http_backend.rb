require 'json'

class Diarizer
  module HTTPBackend
    module_function

    def diarize(api, path, speakers: nil)
      Zipper::AudioOps.with_speech_wav(path) do |file|
        params = {file: file}
        params[:speakers] = speakers.to_i.to_s if speakers.to_i.positive?
        response = Utils::HTTP.post(Utils::HTTP.url(api, '/v1/diarize'), params)
        Utils::HTTP.assert_ok!(response, 'diarization')

        Result.from_json(response.body)
      end
    end
  end
end
