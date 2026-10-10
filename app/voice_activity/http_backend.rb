require 'json'

class VoiceActivity
  module HTTPBackend
    module_function

    def detect(api, path)
      Zipper::AudioOps.with_speech_wav(path) do |file|
        response = Utils::HTTP.post(Utils::HTTP.url(api, '/v1/vad'), file: file)
        Utils::HTTP.assert_ok!(response, 'voice activity detection')

        parse(response.body)
      end
    end

    def parse(body)
      data      = JSON.parse(body)
      segments  = data.fetch('segments')
      intervals = segments.map do |segment|
        Utils::TimeRanges::Interval.new(start: Float(segment.fetch('start')), finish: Float(segment.fetch('end')))
      end
      Utils::TimeRanges.new(intervals, option: :vad)
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError
      raise ArgumentError, 'voice activity detection returned malformed speech ranges'
    end
  end
end
