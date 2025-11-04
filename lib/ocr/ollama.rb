require 'base64'
require_relative '../ai/ollama'

class Ocr
  module Ollama
    PROMPT = "Recognize the text in this image. Preserve original word spacing (do not merge words). Skip the book page headers or footers. Output only the plain text exactly as seen, with each heading or paragraph separated by a blank line. Do NOT return JSON, markup, or commentary—just the text.".freeze
    PROMPT_INCLUDE_ALL = "Recognize the text in this image. Preserve original word spacing (do not merge words). Include everything present, including any headers, footers, page numbers, and marginalia. Output only the plain text exactly as seen, with each heading or paragraph separated by a blank line. Do NOT return JSON, markup, or commentary—just the text.".freeze

    def self.transcribe(image_path, timeout_sec: 135, opts: nil, **_kwargs)
      base64 = Base64.strict_encode64(File.binread(image_path))
      include_all = !!(opts && (opts[:includeall] || opts['includeall']))
      messages = [{ role: :user, content: (include_all ? PROMPT_INCLUDE_ALL : PROMPT), images: [base64] }]
      text_content = AI::Ollama.chat(messages)
      SymMash.new(content: { text: text_content })
    end
  end
end
