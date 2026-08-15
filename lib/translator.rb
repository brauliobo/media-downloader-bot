require 'srt'
require 'securerandom'
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
  def self.translate_srt srt, to:, from: nil
    srt    = SRT::File.parse_string srt
    srt.lines.reject!{ |l| l.text.blank? } # workaround whisper issue
    lines = srt.lines.flat_map{ |line| line.text }
    masked, replacements, marker_pattern = protect_srt_timestamps(lines)
    tlines = masked.each_slice(BATCH_SIZE).with_object [] do |slice, translated|
      translated.concat Array.wrap(translate slice, from: from, to: to)
    end
    tlines = tlines.zip(replacements).map do |text, line_replacements|
      expected = line_replacements.map(&:first)
      actual   = text.to_s.scan(marker_pattern)
      raise "SRT translation corrupted inline timestamps: expected #{expected.join(', ')}" unless actual == expected

      values = line_replacements.to_h
      text.gsub(marker_pattern) { |marker| values.fetch(marker) }
    end

    i = 0
    srt.lines.each do |line|
      line.text = line.text.map{ |segment| tlines[i].tap{ i+= 1 } }
    end

    srt.to_s
  end

  def self.protect_srt_timestamps(lines)
    prefix = nil
    loop do
      candidate = "__SRT_TS_#{SecureRandom.hex(8)}_"
      unless lines.any? { |line| line.include?(candidate) }
        prefix = candidate
        break
      end
    end
    marker_pattern = /#{Regexp.escape(prefix)}\d+__/
    index = 0
    replacements = []
    masked = lines.map do |text|
      line_replacements = []
      protected_text = text.gsub(Subtitler::INLINE_TIMESTAMP) do |timestamp|
        marker = "#{prefix}#{index}__"
        index += 1
        line_replacements << [marker, timestamp]
        marker
      end
      replacements << line_replacements
      protected_text
    end
    [masked, replacements, marker_pattern]
  end
  private_class_method :protect_srt_timestamps

  def self.translate_vtt vtt, to:, from: nil
    Subtitler::VTT.translate(vtt, to: to, from: from)
  end

end
