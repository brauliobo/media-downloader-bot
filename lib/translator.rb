require_relative 'translator/nllb_serve'
require_relative 'translator/ollama'
require_relative 'translator/llamacpp_api'
require_relative 'translator/madlad400'

class Translator

  BACKEND_CLASS = const_get ENV['TRANSLATOR'].to_sym

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
    lines, idxs, txts = vtt.lines, [], []
    lines.each_with_index do |l,i|
      s = l.strip
      next if (i.zero? && s.start_with?('WEBVTT')) || s.empty? || s.include?('-->') || %w[NOTE STYLE REGION].any?{ |p| s.start_with?(p) }
      idxs << i; txts << s
    end

    ttxts = txts.each_slice(BATCH_SIZE).with_object([]){ |chs,acc| acc.concat Array.wrap(translate chs, from: from, to: to) }

    idxs.each_with_index{ |li,j| lines[li] = lines[li].sub(txts[j], ttxts[j]) }
    lines.join
  end

end

