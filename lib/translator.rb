require_relative 'translator/nllb_serve'
require_relative 'translator/ollama'
require_relative 'translator/llamacpp_api'
require_relative 'translator/madlad400'
require_relative 'subtitler/vtt'

class Translator

  BACKEND_CLASS = const_get ENV['TRANSLATOR'].to_sym if ENV['TRANSLATOR']

  extend BACKEND_CLASS

  BATCH_SIZE = 50

  def self.translate_srt srt, to:, from: nil
    srt    = SRT::File.parse_string srt
    srt.lines.reject!{ |l| l.text.blank? } # workaround whisper issue
    lines  = srt.lines.flat_map{ |line| line.text }
    tlines = lines.each_slice(BATCH_SIZE).with_object [] do |slines, stlines|
      stlines.concat Array.wrap(translate slines, from: from, to: to)
    end

    i = 0
    srt.lines.each do |line|
      line.text = line.text.map{ |segment| tlines[i].tap{ i+= 1 } }
    end

    srt.to_s
  end

  def self.translate_vtt vtt, to:, from: nil
    Subtitler::VTT.translate(vtt, to: to, from: from)
  end

end

