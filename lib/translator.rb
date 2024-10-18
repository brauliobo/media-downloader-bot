require_relative 'translator/nllb_serve'
require_relative 'translator/ollama'

class Translator

  BACKEND_CLASS = const_get ENV['TRANSLATOR'].to_sym

  extend BACKEND_CLASS

  def self.translate_srt srt, from:, to:
    srt    = SRT::File.parse_string srt
    srt.lines.reject!{ |l| l.text.blank? } # workaround whisper issue
    lines  = srt.lines.flat_map{ |line| line.text }
    tlines = lines.each_slice(100).with_object [] do |slines, stlines|
      stlines.concat translate slines, from: from, to: to
    end

    i = 0
    srt.lines.each do |line|
      line.text = line.text.map{ |segment| tlines[i].tap{ i+= 1 } }
    end

    srt.to_s
  end

end

