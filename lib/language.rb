require 'json'
require 'timeout'
require_relative 'ai/ollama'
require_relative 'ai/json_schema'

module Language
  BOOK_PROMPT     = "From the supplied first pages or metadata, detect the predominant language as an ISO 639-1 two-letter code (do not return `en` unless the text is actually English), identify the book title and author, and infer the author's likely gender for choosing an audiobook narrator voice. Return gender as exactly `male` or `female`. If the title or author is unknown, return an empty string for that field. If the author is unknown, ambiguous, a group, an organization, or gender cannot be inferred confidently, return `male`. Return only valid JSON.".freeze
  REF_PROMPT      = "Write one neutral audiobook narrator reference sentence in the requested language, between 12 and 20 words. Return only valid JSON.".freeze
  REF_FALLBACK    = 'This narrator voice reads the audiobook with calm, clear, natural pacing and keeps a steady tone across sentences.'.freeze
  REF_FALLBACKS   = {
    'en' => REF_FALLBACK,
    'pt' => 'Esta voz narra o audiolivro com calma, clareza e ritmo natural, mantendo o mesmo tom em todas as frases.',
  }.freeze
  MIN_REF_CHARS   = 80
  BOOK_SCHEMA     = AI::JSONSchema.object(
    lang:   { type: 'string', pattern: '^[a-z]{2}$' },
    title:  { type: 'string' },
    author: { type: 'string' },
    gender: { type: 'string', enum: %w[male female] }
  ).freeze
  REF_SCHEMA      = AI::JSONSchema.object(text: { type: 'string', minLength: 1 }).freeze
  AI_BACKEND      = AI::Ollama
  BOOK_DEFAULTS   = { 'lang' => '', 'title' => '', 'author' => '', 'gender' => 'male' }.freeze

  def self.detect(paragraphs)
    raise ArgumentError, 'no text available for language detection' unless paragraphs.any?

    lang = book_metadata(paragraphs_text(paragraphs))['lang']
    lang.presence || raise('language detection returned no valid result')
  end

  def self.voice_reference_text(lang)
    lang = lang.to_s.strip
    lang = 'en' if lang.empty?
    text = ask(REF_PROMPT, REF_SCHEMA, "Language code: #{lang}")['text'].to_s.strip
    stable_reference_text(text, lang)
  rescue Timeout::Error, StandardError
    reference_fallback(lang)
  end

  def self.book_metadata(input)
    info   = ask(BOOK_PROMPT, BOOK_SCHEMA, input)
    gender = info['gender'].to_s.downcase.strip
    lang   = info['lang'].to_s.downcase.strip
    {
      'lang'   => lang.match?(/^[a-z]{2}$/) ? lang : '',
      'title'  => info['title'].to_s.strip,
      'author' => info['author'].to_s.strip,
      'gender' => %w[male female].include?(gender) ? gender : 'male',
    }
  rescue Timeout::Error, StandardError
    BOOK_DEFAULTS.dup
  end

  def self.author_gender(input)
    book_metadata(input)['gender']
  end

  def self.book_input(metadata, sample)
    ["Metadata:\n#{metadata.to_h}", "First pages:\n#{sample}"].join("\n\n")
  end

  def self.ask(task, schema, input)
    AI::JSONSchema.ask(backend: AI_BACKEND, task: task, schema: schema, input: input)
  end

  def self.paragraphs_text(paragraphs)
    paragraphs.map { |para| para[:text].to_s.strip }.reject(&:empty?).join("\n")
  end

  def self.stable_reference_text(text, lang)
    text.length >= MIN_REF_CHARS ? text : reference_fallback(lang)
  end

  def self.reference_fallback(lang)
    REF_FALLBACKS[lang.to_s] || REF_FALLBACK
  end

end
