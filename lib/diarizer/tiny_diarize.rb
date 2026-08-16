require 'json'
require 'uri'

require_relative 'result'
require_relative '../subtitler/subtitle'
require_relative '../utils/http'
require_relative '../zipper'

class Diarizer
  module TinyDiarize
    mattr_accessor :api
    self.api = URI.parse(ENV.fetch('DIARIZER_SERVER', 'http://127.0.0.1:8081'))

    module_function

    def diarize(path, speakers: nil)
      Zipper.with_audio_wav(path) do |file|
        response = Utils::HTTP.post(
          "#{api.to_s.delete_suffix('/')}/inference",
          file:            file,
          language:        'en',
          temperature:     '0.0',
          response_format: 'verbose_json',
          tinydiarize:     'true'
        )
        raise "diarization failed: #{response.code}" unless response.code == '200'

        subtitle = Subtitler::Subtitle.from_whisper_verbose_json(response.body)
        unless subtitle.entries.all? { |entry| entry.metadata.key?('speaker_turn_next') }
          raise 'TinyDiarize service did not return speaker_turn_next'
        end

        assign_speaker_ids(subtitle.entries, speakers)
        Result.new(segments: subtitle.entries.map do |entry|
          Segment.new(start: entry.start, finish: entry.finish, speaker_id: entry.speaker_id)
        end)
      end
    end

    def assign_speaker_ids(segments, speaker_count)
      speaker_id = 0
      segments.each do |segment|
        segment.assign_speaker!(speaker_id)
        next unless segment.metadata.fetch('speaker_turn_next')

        speaker_id += 1
        speaker_id %= speaker_count if speaker_count.to_i.positive?
      end
    end

    extend self
  end
end
