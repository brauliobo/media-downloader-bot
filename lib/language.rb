require 'json'
require 'timeout'
require_relative 'ai/ollama'
require_relative 'ai/json_schema'

module Language
  PROMPT_TEMPLATE = "Detect the predominant language of this text chunk by the majority of the text content. Return the ISO 639-1 two-letter language code. Do not return `en` unless this chunk is actually English.".freeze
  REF_PROMPT      = "Write one neutral audiobook narrator reference sentence in the requested language, between 12 and 20 words. Return only valid JSON.".freeze
  AUTHOR_PROMPT   = "Identify the book author from the supplied first pages or metadata, then infer the author's likely gender for choosing an audiobook narrator voice. Return gender as exactly `male` or `female`. If the author is unknown, ambiguous, a group, an organization, or gender cannot be inferred confidently, return `male`. Return only valid JSON.".freeze
  REF_FALLBACK    = 'This narrator voice reads the audiobook with calm, clear, natural pacing and keeps a steady tone across sentences.'.freeze
  REF_FALLBACKS   = {
    'en' => REF_FALLBACK,
    'pt' => 'Esta voz narra o audiolivro com calma, clareza e ritmo natural, mantendo o mesmo tom em todas as frases.',
  }.freeze
  MIN_REF_CHARS   = 80
  SCHEMA          = AI::JSONSchema.object(lang: { type: 'string', pattern: '^[a-z]{2}$' }).freeze
  REF_SCHEMA      = AI::JSONSchema.object(text: { type: 'string', minLength: 1 }).freeze
  AUTHOR_SCHEMA   = AI::JSONSchema.object(
    author: { type: 'string' },
    gender: { type: 'string', enum: %w[male female] }
  ).freeze
  AI_BACKEND      = AI::Ollama
  CHUNK_SIZE      = 2_000
  MAX_CHUNKS      = 8

  def self.detect(paragraphs)
    raise ArgumentError, 'no text available for language detection' unless paragraphs.any?

    votes = language_chunks(paragraphs).each_with_object(Hash.new(0)) do |chunk, acc|
      lang = detect_chunk(chunk)
      acc[lang] += chunk.length if lang
    end
    votes.max_by { |_lang, weight| weight }&.first || raise('language detection returned no valid result')
  end

  def self.voice_reference_text(lang)
    lang = lang.to_s.strip
    lang = 'en' if lang.empty?
    text = ask(REF_PROMPT, REF_SCHEMA, "Language code: #{lang}")['text'].to_s.strip
    stable_reference_text(text, lang)
  rescue Timeout::Error, StandardError
    reference_fallback(lang)
  end

  def self.author_gender(input)
    gender = ask(AUTHOR_PROMPT, AUTHOR_SCHEMA, input)['gender'].to_s.downcase.strip
    %w[male female].include?(gender) ? gender : 'male'
  rescue Timeout::Error, StandardError
    'male'
  end

  def self.ask(task, schema, input)
    AI::JSONSchema.ask(backend: AI_BACKEND, task: task, schema: schema, input: input)
  end

  def self.detect_chunk(chunk)
    lang = ask(PROMPT_TEMPLATE, SCHEMA, "Text:\n#{chunk}")['lang'].downcase.strip
    lang if lang.match?(/^[a-z]{2}$/)
  end

  def self.language_chunks(paragraphs)
    text = paragraphs.map { |p| p[:text].to_s.strip }.reject(&:empty?).join("\n")
    chunks = text.scan(/.{1,#{CHUNK_SIZE}}/m).first(MAX_CHUNKS)
    chunks.reject { |chunk| chunk.strip.empty? }
  end

  def self.stable_reference_text(text, lang)
    text.length >= MIN_REF_CHARS ? text : reference_fallback(lang)
  end

  def self.reference_fallback(lang)
    REF_FALLBACKS[lang.to_s] || REF_FALLBACK
  end

end
