require 'json'
require 'timeout'
require_relative 'ai/ollama'

module Language
  PROMPT_TEMPLATE = "What is the ISO 639-1 two-letter language code of the following text? Respond with ONLY the code (e.g., `en`, `es`).\n\n".freeze
  SCHEMA = {type:'object',properties:{lang:{type:'string'}},required:['lang']}.freeze
  USE_AI_LANG = ENV.fetch('AI_LANG', '1') == '1'

  def self.detect(paragraphs)
    return 'en' unless USE_AI_LANG && paragraphs.any?
    sample_text = paragraphs.first(5).map { |p| p[:text] }.join("\n")[0, 1000]
    messages = [{ role: :user, content: PROMPT_TEMPLATE + """\n#{sample_text}\n""" }]
    ans = AI::Ollama.chat(messages, timeout: 15, format: SCHEMA)
    lang = JSON.parse(ans)['lang']&.downcase&.strip
    lang&.match?(/^[a-z]{2}$/) ? lang : 'en'
  rescue StandardError
    'en'
  end
end


