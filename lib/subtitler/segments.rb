require_relative 'subtitle'

class Subtitler
  module Segments
    module_function

    def merge_adjacent!(subtitle, **options)
      raise TypeError, 'subtitle must be a Subtitler::Subtitle' unless subtitle.is_a?(Subtitle)

      subtitle.merge_adjacent!(**options)
    end
  end
end
