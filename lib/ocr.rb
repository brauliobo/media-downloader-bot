require_relative 'ocr/ollama'
require_relative 'ocr/pdf'
require_relative 'ocr/epub'

class Ocr

  BACKEND_CLASS = const_get(ENV['OCR'] || 'Ollama')

  extend BACKEND_CLASS

  # Route transcription by file type. For PDFs, prefer embedded text when present;
  # for EPUBs, parse XHTML; otherwise fall back to default backend.
  def self.transcribe(input_path, json_path, **kwargs)
    ext = File.extname(input_path).downcase
    case ext
    when '.pdf'
      return Pdf.transcribe(input_path, json_path, **kwargs) if Pdf.has_text?(input_path)
      return BACKEND_CLASS.transcribe(input_path, json_path, **kwargs)
    when '.epub'
      return Epub.transcribe(input_path, json_path, **kwargs)
    else
      return BACKEND_CLASS.transcribe(input_path, json_path, **kwargs)
    end
  end

  # ---------- Generic helpers (backend-agnostic) ----------
  def heading_line?(text)
    words = text.split(/\s+/)
    return false if words.empty? || words.size > 10
    upper_ratio = words.count { |w| w == w.upcase }.fdiv(words.size)
    return true if upper_ratio > 0.8
    return true if words.all? { |w| w.match?(/\A[A-Z][a-z]+\z/) }
    false
  end

  def normalize_text(str)
    # Ensure UTF-8 encoding and handle invalid characters
    clean_str = str.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
    clean_str.gsub("\u00A0", ' ').gsub(/<[^>]+>/, '').gsub(/\s+/, ' ').strip
  end

  def merge_paragraphs(paragraphs)
    result = []
    paragraphs.each do |para|
      blocks = para[:text].to_s.split(/\n{2,}/).map { |b| normalize_text(b) }.reject(&:empty?)
      blocks.each do |block|
        lines = block.split(/\n+/).map { |l| normalize_text(l) }.reject(&:empty?)
        lines.each do |line|
          if heading_line?(line)
            result << SymMash.new(text: line, page_numbers: para[:page_numbers].dup, merged: false, kind: 'heading')
            next
          end
          if result.any? && result.last[:text] !~ /[\.!?？¡!;:]"?$/ && result.last[:kind] != 'heading'
            result.last[:text] << ' ' << line
            result.last[:page_numbers] |= para[:page_numbers]
            result.last[:merged] = true
          else
            result << SymMash.new(text: line, page_numbers: para[:page_numbers].dup, merged: para[:merged] || false, kind: 'text')
          end
        end
      end
    end
    result
  end

  # provide singleton-like helper instance
  def self.util
    @util ||= new
  end

end