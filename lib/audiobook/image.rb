require 'json'
require 'securerandom'
require 'fileutils'
require 'tmpdir'
require_relative 'paragraph'
require_relative '../ocr'

module Audiobook
  # Represents an image that needs OCR, then generates audio like a paragraph
  class Image < Paragraph
    attr_reader :path

    def initialize(path)
      @path = path
      @sentences = []
      ocr!
    end

    def to_h
      { 'image' => { 'path' => path, 'sentences' => sentences.map(&:to_h) } }
    end

    private

    # Run OCR and extract sentences
    def ocr!
      return if @sentences.any?
      
      tmp_json = File.join(Dir.tmpdir, "ocr-#{SecureRandom.hex(4)}.json")
      Ocr.transcribe(path, tmp_json)
      data = JSON.parse(File.read(tmp_json))
      
      text = data['text'] || data.dig('content', 'text') || ''
      return if text.strip.empty?
      
      # Split into sentences like Paragraph does
      normalized = Ocr.util.normalize_text(text)
        .gsub(/[\u0000-\u001F\u007F-\u009F]/, '').gsub(/\u00AD/, '').gsub(/\s+/, ' ').strip
      parts = normalized.gsub(/([.!?…]\"?)\s+(?=\p{Lu})/u, "\\1\n").split(/\n+/)
      @sentences = parts.map { |s| Sentence.new(s) }.reject { |s| s.text.empty? }
    ensure
      FileUtils.rm_f(tmp_json) if tmp_json
    end
  end
end
