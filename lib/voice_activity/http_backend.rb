require 'json'

require_relative '../utils/http'
require_relative '../utils/time_ranges'
require_relative '../zipper'

class VoiceActivity
  module HTTPBackend
    module_function

    def detect(api, path)
      Zipper.with_audio_wav(path, sample_rate: 16_000, channels: 1) do |file|
        response = Utils::HTTP.post("#{api.to_s.delete_suffix('/')}/v1/vad", file: file)
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
