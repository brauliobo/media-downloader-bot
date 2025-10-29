require_relative 'subtitler/whisper_cpp'
require_relative 'subtitler/vtt'
require_relative 'subtitler/srt'

class Subtitler

  BACKEND_CLASS = const_get ENV['SUBTITLER'].to_sym

  extend BACKEND_CLASS

  TAG_REGEX = /<\d{2}:\d{2}:\d{2}[,.]\d{3}>/
  def self.strip_word_tags str
    str.gsub(TAG_REGEX, '')
  end

  def self.normalize_lang(lang)
    return nil if lang.nil?
    raw = lang.to_s.strip.downcase
    entry = ISO_639.find_by_code(raw) || ISO_639.find_by_english_name(raw.capitalize)
    entry&.alpha2
  end
end
