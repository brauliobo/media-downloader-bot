module Dubbing
  module Audio
    Clip = Data.define(:path, :start, :end, :speaker_id) do
      def initialize(speaker_id: nil, **attributes) = super(speaker_id: speaker_id, **attributes)
    end
  end
end
