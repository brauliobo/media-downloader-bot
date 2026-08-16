require 'json'
require_relative 'ai/ollama'
require_relative 'ai/json_schema'
require_relative 'subtitler/subtitle'

module Shorts
  module_function

  CUT_SCHEMA = {
    type:  'array',
    items: AI::JSONSchema.object(
      start: { type: 'string', pattern: '^\\d{2}:\\d{2}:\\d{2}$' },
      end:   { type: 'string', pattern: '^\\d{2}:\\d{2}:\\d{2}$' },
      title: { type: 'string' }
    ),
  }.freeze
  TITLE_SCHEMA = AI::JSONSchema.object(title: { type: 'string', minLength: 1 }).freeze
  MODEL = ENV['OLLAMA_SHORTS_MODEL'] || AI::Ollama::PROMPT_MODEL

  Cut = Data.define(:start, :finish, :title) do
    TIMESTAMP = /\A\d{2}:\d{2}:\d{2}\z/

    def initialize(start:, finish:, title:)
      start_time  = Subtitler.parse_timestamp(start) if start.is_a?(String) && start.match?(TIMESTAMP)
      finish_time = Subtitler.parse_timestamp(finish) if finish.is_a?(String) && finish.match?(TIMESTAMP)
      valid = start.is_a?(String) && finish.is_a?(String) && title.is_a?(String) &&
        start_time && finish_time && finish_time > start_time
      raise ArgumentError, 'short cut is malformed' unless valid

      super
    end
  end

  def generate_cuts(subtitle, language: nil)
    require_subtitle!(subtitle)
    task = <<~PROMPT
      From the SRT transcript below, propose 4-10 short video cuts.

      Rules:
      - Choose the most engaging moments; keep each cut ~30-75 seconds; no overlaps
      - Cut on sentence boundaries when possible
      - Times must be HH:MM:SS (no milliseconds). Use only the transcript timing
      #{language ? "- Titles in: #{language}" : '- Titles in the subtitle language'}
    PROMPT

    arr = ask_json(task, CUT_SCHEMA, <<~INPUT)
      Transcript (SRT):
      #{subtitle.to_srt}
    INPUT
    arr = [arr] if arr.is_a?(Hash)
    arr = [] unless arr.is_a?(Array)
    arr.filter_map do |h|
      next unless h.is_a?(Hash)
      s, e, t = h.values_at('start', 'end', 'title')
      Cut.new(start: s, finish: e, title: normalize_title(t))
    rescue ArgumentError, TypeError
      nil
    end
  end

  def generate_titles(subtitles, language: nil)
    subtitles.map { |subtitle| generate_title(subtitle, language: language) }
  end

  def generate_title(subtitle, language: nil)
    require_subtitle!(subtitle)
    snippet = subtitle.entries.map(&:text).join(' ').strip
    lang_instruction = language.to_s.strip.present? ? "Generate the title in: #{language}." : 'Generate the title in the subtitle language.'

    task = <<~PROMPT
      Given this subtitle excerpt of a short video, produce ONE concise, compelling title.

      Rules:
      - #{lang_instruction}
      - 4-10 words; no hashtags/emojis; no quotes/brackets
      - Use ONLY the excerpt content; do not invent names or facts
    PROMPT

    data = ask_json(task, TITLE_SCHEMA, <<~INPUT)
      Excerpt:
      #{snippet}
    INPUT
    normalize_title(data['title'])
  end

  def ask_json(task, schema, input)
    AI::JSONSchema.ask(backend: AI::Ollama, task: task, schema: schema, input: input, model: MODEL)
  end

  def normalize_title(t)
    s = t.to_s.strip
    return s if s.empty?
    begin
      parsed = JSON.parse(s)
      s = parsed['title'] || parsed.first if parsed.is_a?(Hash) || parsed.is_a?(Array)
    rescue JSON::ParserError; end
    s = s.to_s.strip.gsub(/^[\[\"]+|[\]\"]+$/, '').gsub(/\s+/, ' ').strip
    s[0, 120]
  end

  def require_subtitle!(subtitle)
    raise TypeError, 'subtitle must be a Subtitler::Subtitle' unless subtitle.is_a?(Subtitler::Subtitle)
  end
end
