require 'iso-639'

require_relative 'voice_separator'

require_relative 'subtitler/timestamps'
require_relative 'subtitler/subtitle'
require_relative 'subtitler/whisper_cpp'
require_relative 'subtitler/transcribe_cpp'
require_relative 'subtitler/vtt'
require_relative 'subtitler/srt'
require_relative 'subtitler/ass'

class Subtitler

  BACKEND_CLASS = const_get ENV['SUBTITLER'].to_sym if ENV['SUBTITLER']

  extend BACKEND_CLASS

  def self.transcribe(path, separate_voice: true, **options)
    return transcribe_with_backend(path, **options) unless separate_voice

    VoiceSeparator.with_stems(path) do |stems|
      transcribe_with_backend(stems.vocals, **options)
    end
  end

  def self.strip_word_tags str
    str.gsub(INLINE_TIMESTAMP, '')
  end

  def self.normalize_lang(lang)
    return nil if lang.nil?
    raw = lang.to_s.strip.downcase
    base = raw.split(/[-_]/, 2).first
    entry = ISO_639.find_by_code(raw) || ISO_639.find_by_code(base) || ISO_639.find_by_english_name(raw.capitalize)
    entry&.alpha2
  end

  def self.transcribe_with_backend(path, **options)
    BACKEND_CLASS.instance_method(:transcribe).bind_call(self, path, **options)
  end
  private_class_method :transcribe_with_backend
end
