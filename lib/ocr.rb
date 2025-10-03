require 'base64'
require_relative 'sh'
require 'mechanize'
require 'timeout'
require_relative 'audiobook/text_helpers'
require_relative 'ocr/ollama'

class Ocr
  BACKEND_CLASS = (ENV['OCR'] || 'Ollama').to_sym

  def self.backend
    @backend ||= const_get("Ocr::#{BACKEND_CLASS}")
  end

  # Delegate transcription to the configured backend
  def self.transcribe(input_path, **kwargs)
    backend.transcribe(input_path, **kwargs)
  end

  # Delegate language detection to the configured backend
  def self.detect_language(paragraphs, **kwargs)
    backend.detect_language(paragraphs, **kwargs)
  end

  # Delegate paragraph merging to the configured backend
  def self.ai_merge_paragraphs(paragraphs, **kwargs)
    backend.ai_merge_paragraphs(paragraphs, **kwargs)
  end
end