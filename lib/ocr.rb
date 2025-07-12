require_relative 'ocr/ollama'

class Ocr

  BACKEND_CLASS = const_get(ENV['OCR'] || 'Ollama')

  extend BACKEND_CLASS

  def self.transcribe(*args, **kwargs)
    BACKEND_CLASS.transcribe(*args, **kwargs)
  end
end