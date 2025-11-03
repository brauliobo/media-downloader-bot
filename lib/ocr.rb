require_relative 'ocr/ollama'
require_relative 'ocr/tesseract'

class Ocr
  BACKEND_CLASS = (ENV['OCR'] || 'Ollama').to_sym

  def self.backend
    @backend ||= const_get("Ocr::#{BACKEND_CLASS}")
  end

  # Delegate transcription to the configured backend
  def self.transcribe(input_path, **kwargs)
    backend.transcribe(input_path, **kwargs)
  end
end
