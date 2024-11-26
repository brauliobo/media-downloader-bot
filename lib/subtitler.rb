require_relative 'subtitler/whisper_cpp'

class Subtitler

  BACKEND_CLASS = const_get ENV['SUBTITLER'].to_sym

  extend BACKEND_CLASS

end


