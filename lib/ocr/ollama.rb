require 'base64'
require_relative '../sh'
require 'mechanize'
require 'timeout'
require_relative '../audiobook/text_helpers'

class Ocr
  module Ollama
    API   = ENV['OLLAMA_HOST']
    MODEL = ENV['OLLAMA_OCR_MODEL']

    PROMPT = "Recognize the text in this image. Preserve original word spacing (do not merge words). Skip the book page headers or footers. Output only the plain text exactly as seen, with each heading or paragraph separated by a blank line. Do NOT return JSON, markup, or commentary—just the text.".freeze
    PROMPT_INCLUDE_ALL = "Recognize the text in this image. Preserve original word spacing (do not merge words). Include everything present, including any headers, footers, page numbers, and marginalia. Output only the plain text exactly as seen, with each heading or paragraph separated by a blank line. Do NOT return JSON, markup, or commentary—just the text.".freeze
    AI_MERGE_PROMPT = "You will be given two consecutive blocks of text extracted from a scanned book page. If they represent a single logical paragraph that was split across lines/pages, respond with ONLY the word YES. Otherwise respond with ONLY the word NO.".freeze
    LANG_PROMPT_TEMPLATE = "What is the ISO 639-1 two-letter language code of the following text? Respond with ONLY the code (e.g., `en`, `es`).\n\n".freeze
    LANG_SCHEMA = {type:'object',properties:{lang:{type:'string'}},required:['lang']}.freeze

    USE_AI_MERGE = ENV.fetch('AI_MERGE', '0') == '1'
    USE_AI_LANG  = ENV.fetch('AI_LANG', '1') == '1'

    def self.chat(messages, timeout: 30, format: nil)
      payload = { model: MODEL, stream: false, options: {temperature: 0.0}, messages: messages }
      payload[:format] = format if format
      res = Timeout.timeout(timeout) { Manager.http.post "#{API}/api/chat", payload.to_json }
      SymMash.new(JSON.parse(res.body)).dig(:message, :content).to_s.strip
    end

    def self.transcribe(image_path, timeout_sec: 135, opts: nil, **_kwargs)
      base64 = Base64.strict_encode64(File.binread(image_path))
      include_all = !!(opts && (opts[:includeall] || opts['includeall']))
      messages = [{ role: :user, content: (include_all ? PROMPT_INCLUDE_ALL : PROMPT), images: [base64] }]
      text_content = chat(messages, timeout: timeout_sec)
      SymMash.new(content: { text: text_content })
    end

    def self.detect_language(paragraphs, timeout_sec: 15)
      return nil unless USE_AI_LANG && paragraphs.any?
      sample_text = paragraphs.first(5).map { |p| p[:text] }.join("\n")[0, 1000]
      messages = [{ role: :user, content: LANG_PROMPT_TEMPLATE + """\n#{sample_text}\n""" }]
      ans = chat(messages, timeout: timeout_sec, format: LANG_SCHEMA)
      lang = (JSON.parse(ans)['lang'] rescue nil)&.downcase&.strip
      lang&.match?(/^[a-z]{2}$/) ? lang : nil
    rescue StandardError
      nil
    end

    def self.ai_merge_paragraphs(paragraphs, timeout_sec: 30)
      return paragraphs unless USE_AI_MERGE
      paragraphs.each_with_object([]) do |para, out|
        if out.any? && out.last[:kind] == 'text' && para[:kind] == 'text'
          prev = out.last
          messages = [
            { role: :user, content: AI_MERGE_PROMPT },
            { role: :assistant, content: '' },
            { role: :user, content: "FIRST:\n#{prev[:text]}\nSECOND:\n#{para[:text]}" }
          ]
          ans = chat(messages, timeout: timeout_sec) rescue nil
          if ans&.upcase == 'YES'
            prev[:text] << ' ' << para[:text]
            prev[:page_numbers] |= para[:page_numbers]
            prev[:merged] = true
            next
          end
        end
        out << para
      end
    end
  end
end
