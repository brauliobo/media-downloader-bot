require_relative 'subtitler/whisper_cpp'

class Subtitler

  BACKEND_CLASS = const_get ENV['SUBTITLER'].to_sym

  extend BACKEND_CLASS

  TAG_REGEX = /<\d{2}:\d{2}:\d{2}[,.]\d{3}>/
  def self.strip_word_tags str
    str.gsub(TAG_REGEX, '')
  end
end
