module Dubbing
  module Audio
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
  end
end
