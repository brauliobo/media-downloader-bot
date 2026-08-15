require 'srt'
require_relative 'translator/nllb_serve'
require_relative 'translator/ollama'
require_relative 'translator/llamacpp_api'
require_relative 'translator/hymt2'
require_relative 'translator/madlad400'
require_relative 'subtitler/timestamps'
require_relative 'subtitler/vtt'

class Translator

  BACKEND_CLASS = const_get ENV.fetch('TRANSLATOR', 'HyMT2').to_sym

  extend BACKEND_CLASS

  BATCH_SIZE = 50
  SRT_TIMESTAMP_PLACEHOLDER = /__T\d{4}__/.freeze

  def self.translate_srt srt, to:, from: nil
    srt    = SRT::File.parse_string srt
    srt.lines.reject!{ |l| l.text.blank? } # workaround whisper issue
    lines     = srt.lines.flat_map{ |line| line.text }
    index     = 0
    protected = lines.map do |text|
      replacements = []
      masked = text.gsub(Subtitler::INLINE_TIMESTAMP) do |timestamp|
        marker = format('__T%04d__', index)
        index += 1
        replacements << [marker, timestamp]
        marker
      end
      [masked, replacements]
    end
    tlines = protected.each_slice(BATCH_SIZE).with_object [] do |slice, translated|
      translated.concat Array.wrap(translate slice.map(&:first), from: from, to: to)
    end
    tlines = tlines.zip(protected).map do |text, (_, replacements)|
      expected = replacements.map(&:first)
      actual   = text.to_s.scan(SRT_TIMESTAMP_PLACEHOLDER)
      raise "SRT translation corrupted inline timestamps: expected #{expected.join(', ')}" unless actual == expected

      values = replacements.to_h
      text.gsub(SRT_TIMESTAMP_PLACEHOLDER) { |marker| values.fetch(marker) }
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
