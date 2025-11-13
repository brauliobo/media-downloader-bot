require_relative 'ocr/ollama'
require_relative 'ocr/tesseract'

class Ocr
  class_attribute :backend,          default: Ocr.const_get((ENV['OCR'] || 'Tesseract').to_sym)
  class_attribute :fallback_backend, default: Ocr.const_get((ENV['OCR_FALLBACK'] || 'Ollama').to_sym)

  def self.transcribe(input_path, **kwargs)
    result = backend.transcribe(input_path, **kwargs)
    return result if result.content.text.present?
    fallback_backend.transcribe(input_path, **kwargs)
  end

end
