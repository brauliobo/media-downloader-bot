module Dubbing
  module Audio
    Timeline = Data.define(:path, :clips, :score) do
      def initialize(path:, clips:, score: nil) = super
    end
  end
end
