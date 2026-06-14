require 'json'
require_relative 'ai/codex'
require_relative 'ai/json_schema'

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

  def generate_cuts_from_srt(srt, language: nil)
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
      #{srt}
    INPUT
    arr = [arr] if arr.is_a?(Hash)
    arr = [] unless arr.is_a?(Array)
    arr.filter_map do |h|
      next unless h.is_a?(Hash)
      s, e, t = h.values_at('start', 'end', 'title')
      next if s.blank? || e.blank?
      { start: s, end: e, title: normalize_title(t) }
    end
  end

  def generate_titles_for_segments(_srt, _segments, language: nil, vtt_slices: nil)
    Array(vtt_slices).map { |vtt| generate_title_for_segment_slice(vtt, language: language) }
  end

  def generate_title_for_segment_slice(vtt, language: nil)
    snippet = vtt_to_text(vtt).to_s.strip
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
    AI::JSONSchema.ask(backend: AI::Codex, task: task, schema: schema, input: input)
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

  def title_from_vtt(vtt)
    return nil if vtt.to_s.strip.empty?
    lines = vtt.each_line.map(&:strip).reject { |l| l.empty? || l.include?('-->') || l.start_with?('WEBVTT', 'NOTE', 'STYLE', 'REGION') }
    text = lines.join(' ')
    return nil if text.blank?
    sentences = text.split(/(?<=[.!?])\s+/)
    pick = sentences.find { |s| s.split.size.between?(4, 12) } || sentences.max_by(&:length)
    return nil unless pick
    pick.split.first(12).join(' ')
  end

  def vtt_to_text(vtt)
    vtt.to_s.each_line.map(&:strip).reject { |l| l.empty? || l.include?('-->') || l.start_with?('WEBVTT', 'NOTE', 'STYLE', 'REGION') }.join(' ')
  end
end
