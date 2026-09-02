require_relative 'speech_speed'

module Dubbing
  module Audio
    Clip = Data.define(:path, :start, :end, :speaker_id) do
      def initialize(speaker_id: nil, **attributes) = super(speaker_id: speaker_id, **attributes)
    end

    ScheduledClip = Data.define(:path, :start, :end, :speed) do
      def initialize(**attributes) = super(**attributes, speed: SpeechSpeed.validate!(attributes.fetch(:speed)))
    end

    Timeline = Data.define(:path, :clips, :score) do
      def initialize(path:, clips:, score: nil) = super
    end
  end
end
