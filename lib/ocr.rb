require_relative 'ocr/ollama'

class Ocr

  BACKEND_CLASS = const_get(ENV['OCR'] || 'Ollama')

  extend BACKEND_CLASS

  def self.transcribe(*args, **kwargs)
    BACKEND_CLASS.transcribe(*args, **kwargs)
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
    str.to_s.gsub("\u00A0", ' ').gsub(/<[^>]+>/, '').gsub(/\s+/, ' ').strip
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