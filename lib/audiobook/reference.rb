require_relative 'paragraph'

module Audiobook
  class Reference < Paragraph
    attr_reader :id
    attr_accessor :source_sentence

    def initialize(id, sentences = [])
      super(Array(sentences).flatten.compact)
      @id = id.to_s
      @source_sentence = nil
    end

    def add_sentences(new_sentences)
      return self if new_sentences.nil?
      Array(new_sentences).flatten.each do |s|
        next unless s
        next if sentences.any? { |existing| existing.equal?(s) }
        sentences << s
      end
      self
    end

    def add_sentence(sentence)
      return unless sentence
      add_sentences([sentence])
      @source_sentence ||= sentence.respond_to?(:source_sentence) ? sentence.source_sentence : nil
      self
    end

    def to_h
      { 'reference' => { 'id' => id, 'sentences' => sentences.map(&:to_h) } }
    end
  end
end


