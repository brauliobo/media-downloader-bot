require 'json'
require 'timeout'
require_relative 'ai/open_code'
require_relative 'ai/json_schema'

module Language
  PROMPT_TEMPLATE = "Detect the main language of the text. Return the ISO 639-1 two-letter language code. Do not return `en` unless the text is actually English.".freeze
  REF_PROMPT      = "Write one short neutral audiobook narrator reference sentence in the requested language. Return only valid JSON.".freeze
  REF_FALLBACK    = 'This is the narrator voice reference for the audiobook.'.freeze
  SCHEMA          = AI::JSONSchema.object(lang: { type: 'string', pattern: '^[a-z]{2}$' }).freeze
  REF_SCHEMA      = AI::JSONSchema.object(text: { type: 'string', minLength: 1 }).freeze
  AI_BACKEND      = AI::OpenCode

  def self.detect(paragraphs)
    return 'en' unless paragraphs.any?
    sample_text = paragraphs.map{ |p| p[:text] }.join("\n")[0, 1000]

    lang = ask(PROMPT_TEMPLATE, SCHEMA, "Text:\n#{sample_text}")['lang'].downcase.strip
    lang.match?(/^[a-z]{2}$/) ? lang : 'en'
  rescue Timeout::Error, StandardError
    'en'
  end

  def self.voice_reference_text(lang)
    lang = lang.to_s.strip
    lang = 'en' if lang.empty?
    text = ask(REF_PROMPT, REF_SCHEMA, "Language code: #{lang}")['text'].to_s.strip
    text.empty? ? REF_FALLBACK : text
  rescue Timeout::Error, StandardError
    REF_FALLBACK
  end

  def self.ask(task, schema, input)
    AI::JSONSchema.ask(backend: AI_BACKEND, task: task, schema: schema, input: input)
  end

end
