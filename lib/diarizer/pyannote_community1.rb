require_relative 'backend'

class Diarizer
  module PyannoteCommunity1
    extend Backend
    server('PYANNOTE_SERVER', 8082)
  end
end
