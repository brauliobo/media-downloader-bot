require_relative 'speech_speed'

module Dubbing
  module Audio
    Clip = Data.define(:path, :start, :end, :speaker_id) do
      def initialize(speaker_id: nil, **attributes) = super(speaker_id: speaker_id, **attributes)
    end

    ScheduledClip = Data.define(:path, :start, :end, :speed, :leading, :trailing, :speech) do
      def initialize(leading: 0.0, trailing: 0.0, speech: nil, **attributes)
        start  = attributes.fetch(:start)
        finish = attributes.fetch(:end)
        super(
          **attributes,
          speed:    SpeechSpeed.validate!(attributes.fetch(:speed)),
          leading:  leading.to_f,
          trailing: trailing.to_f,
          speech:   speech.nil? ? (finish.to_f - start.to_f) : speech.to_f
        )
      end
    end

    Timeline = Data.define(:path, :clips, :score) do
      def initialize(path:, clips:, score: nil) = super
    end
  end
end
