require 'json'
require 'mechanize'

module Shorts
  API   = ENV['OLLAMA_HOST']
  MODEL = ENV['OLLAMA_SHORTS_MODEL'] || ENV['OLLAMA_MODEL']

  module_function

  SHORTS_JSON_SCHEMA = {
    type: :array,
    items: {
      type: :object,
      properties: {
        start: { type: :string, description: 'HH:MM:SS start time' },
        end:   { type: :string, description: 'HH:MM:SS end time' },
        title: { type: :string, description: 'Short cut title' },
      },
      required: %w[start end title],
      additionalProperties: false,
    },
  }

  TITLES_JSON_SCHEMA = {
    type: :array,
    items: { type: :string, description: 'Title for the corresponding segment' }
  }

  SINGLE_TITLE_SCHEMA = {
    type: :object,
    properties: {
      title: { type: :string, description: 'Concise, compelling title' }
    },
    required: ["title"],
    additionalProperties: false,
  }

  def generate_cuts_from_srt(srt, language: nil)
    prompt = <<~PROMPT
      Task: From the SRT transcript below, propose 4–10 short video cuts.

      Rules:
      - Choose the most engaging moments; keep each cut ~30–75 seconds; no overlaps
      - Cut on sentence boundaries when possible; avoid mid-word or mid-sentence starts
      - Times must be HH:MM:SS (no milliseconds). Use only the transcript timing
      - Return ONLY valid JSON, nothing else, in the format:
        [{"start":"00:00:00","end":"00:00:59"}]

      Transcript (SRT):
      #{srt}
    PROMPT

    body = chat_with_schema(prompt)
    content = safe_content(body)
    json = safe_json(content)
    arr = json.is_a?(Array) ? json : (json.is_a?(Hash) ? [json] : [])
    arr.map do |h|
      next unless h.is_a?(Hash)
      {start: h['start'] || h[:start], end: h['end'] || h[:end]}.symbolize_keys
    end.compact.reject{ |h| h[:start].blank? || h[:end].blank? }
  end

  def generate_titles_for_segments(_srt, _segments, language: nil, vtt_slices: nil)
    vtt_slices = Array(vtt_slices)
    vtt_slices.map do |vtt|
      generate_title_for_segment_slice(vtt, language: language)
    end
  end

  def generate_title_for_segment(srt, segment, language: nil)
    lang_instruction = if language.to_s.strip.present?
      "Generate the title in: #{language}."
    else
      "Generate the title using the subtitle language."
    end

    seg_json = {start: segment[:start], end: segment[:end]}.to_json
    prompt = <<~PROMPT
      Task: Given the SRT transcript and a single segment (start/end HH:MM:SS),
      produce ONE concise, compelling title for this segment.

      Rules:
      - #{lang_instruction}
      - 4–10 words; no hashtags/emojis; no quotes/brackets; not keywords or summaries
      - Return ONLY JSON: {"title":"..."}

      Segment:
      #{seg_json}

      Transcript (SRT):
      #{srt}
    PROMPT

    body = chat_single_title_with_schema(prompt)
    content = safe_content(body)
    data = safe_json(content)
    title = if data.is_a?(Hash)
      data['title'] || data[:title]
    else
      Array(data).first
    end
    normalize_title(title)
  end

  def generate_title_for_segment_slice(vtt, language: nil)
    lang_instruction = if language.to_s.strip.present?
      "Generate the title in: #{language}."
    else
      "Generate the title using the subtitle language."
    end

    snippet = vtt_to_text(vtt).to_s.strip
    prompt = <<~PROMPT
      Task: Given the subtitle excerpt of a single short video, produce ONE concise, compelling title.

      Rules:
      - #{lang_instruction}
      - 4–10 words; no hashtags/emojis; no quotes/brackets; not keywords or summaries
      - Use ONLY the excerpt content below; do not invent names or facts
      - Return ONLY JSON: {"title":"..."}

      Excerpt:
      #{snippet}
    PROMPT

    body = chat_single_title_with_schema(prompt)
    content = safe_content(body)
    data = safe_json(content)
    title = if data.is_a?(Hash)
      data['title'] || data[:title]
    else
      Array(data).first
    end
    normalize_title(title)
  end

  def chat(content)
    raise 'OLLAMA_HOST not set'           if API.to_s.strip.empty?
    raise 'OLLAMA_SHORTS_MODEL not set'   if MODEL.to_s.strip.empty?

    opts = {
      model: MODEL,
      temperature: 0,
      format: 'json',
      stream: false,
      messages: [
        {role: :system, content: 'Return JSON ONLY matching the provided schema. No prose, no code fences.'},
        {role: :user, content: content}
      ]
    }
    begin
      Translator::Ollama.http.post("#{API}/api/chat", opts.to_json, {'Content-Type' => 'application/json'}).body.to_s
    rescue Mechanize::ResponseCodeError => e
      body = e.page&.body.to_s rescue ''
      raise "ollama chat failed (#{e.response_code}): #{body.presence || e.message}"
    end
  end

  def chat_with_schema(content)
    raise 'OLLAMA_HOST not set'           if API.to_s.strip.empty?
    raise 'OLLAMA_SHORTS_MODEL not set'   if MODEL.to_s.strip.empty?

    schema_format = {
      type: 'json_schema',
      json_schema: { name: 'ShortsCuts', schema: SHORTS_JSON_SCHEMA }
    }
    base = {
      model: MODEL,
      temperature: 0,
      stream: false,
      messages: [
        {role: :system, content: 'Return JSON ONLY matching the provided schema. No prose, no code fences.'},
        {role: :user, content: content}
      ]
    }

    # Try schema-enforced output first, then plain json, then /api/generate
    opts = base.merge(format: schema_format)
    return Translator::Ollama.http.post("#{API}/api/chat", opts.to_json, {'Content-Type' => 'application/json'}).body.to_s
  rescue Mechanize::ResponseCodeError
    begin
      opts = base.merge(format: 'json')
      return Translator::Ollama.http.post("#{API}/api/chat", opts.to_json, {'Content-Type' => 'application/json'}).body.to_s
    rescue Mechanize::ResponseCodeError
      # Final fallback: /api/generate single-prompt
      gen = {
        model: MODEL,
        prompt: content + "\n\nReturn ONLY valid JSON matching the schema: #{SHORTS_JSON_SCHEMA.to_json}",
        format: 'json',
        stream: false,
        options: { temperature: 0 }
      }
      return Translator::Ollama.http.post("#{API}/api/generate", gen.to_json, {'Content-Type' => 'application/json'}).body.to_s
    end
  end

  def chat_titles_with_schema(content)
    raise 'OLLAMA_HOST not set'           if API.to_s.strip.empty?
    raise 'OLLAMA_SHORTS_MODEL not set'   if MODEL.to_s.strip.empty?

    schema_format = {
      type: 'json_schema',
      json_schema: { name: 'ShortsTitles', schema: TITLES_JSON_SCHEMA }
    }
    base = {
      model: MODEL,
      temperature: 0,
      stream: false,
      messages: [
        {role: :system, content: 'Return JSON ONLY. No prose, no code fences.'},
        {role: :user, content: content}
      ]
    }

    opts = base.merge(format: schema_format)
    return Translator::Ollama.http.post("#{API}/api/chat", opts.to_json, {'Content-Type' => 'application/json'}).body.to_s
  rescue Mechanize::ResponseCodeError
    begin
      opts = base.merge(format: 'json')
      return Translator::Ollama.http.post("#{API}/api/chat", opts.to_json, {'Content-Type' => 'application/json'}).body.to_s
    rescue Mechanize::ResponseCodeError
      gen = {
        model: MODEL,
        prompt: content + "\n\nReturn ONLY a JSON array of strings matching the number of segments.",
        format: 'json',
        stream: false,
        options: { temperature: 0 }
      }
      return Translator::Ollama.http.post("#{API}/api/generate", gen.to_json, {'Content-Type' => 'application/json'}).body.to_s
    end
  end

  def chat_single_title_with_schema(content)
    raise 'OLLAMA_HOST not set'           if API.to_s.strip.empty?
    raise 'OLLAMA_SHORTS_MODEL not set'   if MODEL.to_s.strip.empty?

    schema_format = {
      type: 'json_schema',
      json_schema: { name: 'ShortsSingleTitle', schema: SINGLE_TITLE_SCHEMA }
    }
    base = {
      model: MODEL,
      temperature: 0,
      stream: false,
      messages: [
        {role: :system, content: 'Return JSON ONLY. No prose, no code fences.'},
        {role: :user, content: content}
      ]
    }

    opts = base.merge(format: schema_format)
    return Translator::Ollama.http.post("#{API}/api/chat", opts.to_json, {'Content-Type' => 'application/json'}).body.to_s
  rescue Mechanize::ResponseCodeError
    begin
      opts = base.merge(format: 'json')
      return Translator::Ollama.http.post("#{API}/api/chat", opts.to_json, {'Content-Type' => 'application/json'}).body.to_s
    rescue Mechanize::ResponseCodeError
      gen = {
        model: MODEL,
        prompt: content + "\n\nReturn ONLY JSON: {\"title\":\"...\"}",
        format: 'json',
        stream: false,
        options: { temperature: 0 }
      }
      return Translator::Ollama.http.post("#{API}/api/generate", gen.to_json, {'Content-Type' => 'application/json'}).body.to_s
    end
  end

  def safe_content(body)
    parsed = JSON.parse(body) rescue nil
    return parsed.dig('message', 'content').to_s.strip if parsed
    body.to_s.strip
  end

  def safe_json(text)
    return text if text.is_a?(Array) || text.is_a?(Hash)
    parsed = (JSON.parse(text) rescue nil)
    return parsed if parsed

    # try to extract array json
    if (m = text[/\[[\s\S]*\]/m])
      begin
        return JSON.parse(m)
      rescue JSON::ParserError
      end
    end
    # try single object and wrap into array
    if (m = text[/\{[\s\S]*\}/m])
      begin
        return JSON.parse(m)
      rescue JSON::ParserError
      end
    end
    []
  end

  # Normalize model output to a concise, human title string
  def normalize_title(t)
    s = t.is_a?(String) ? t.dup : t.to_s
    s.strip!
    # If it looks like a JSON array (e.g., ["keywords", "..."]) pick the best element
    begin
      parsed = JSON.parse(s)
      if parsed.is_a?(Array)
        # drop common labels and pick the first meaningful string
        cand = parsed.find { |e| e.is_a?(String) && e.strip.downcase !~ /^(keywords?|transcription|title)$/ }
        s = cand || parsed.find { |e| e.is_a?(String) } || s
      elsif parsed.is_a?(Hash) && parsed['title']
        s = parsed['title']
      end
    rescue JSON::ParserError
      # not JSON; keep as is
    end
    # Remove wrapping quotes and brackets remnants
    s = s.to_s.strip
    s.gsub!(/^[\[\"]+|[\]\"]+$/, '')
    # Collapse whitespace, cap length
    s = s.gsub(/\s+/, ' ').strip
    s = s[0, 120]
    s
  end

  # Derive a short, human title from a VTT snippet (no model)
  def title_from_vtt(vtt)
    return nil if vtt.to_s.strip.empty?
    lines = vtt.each_line.map(&:strip)
    text_lines = lines.reject { |l| l.empty? || l.include?('-->') || l.start_with?('WEBVTT', 'NOTE', 'STYLE', 'REGION') }
    text = text_lines.join(' ')
    return nil if text.blank?
    # split into sentences
    sentences = text.split(/(?<=[.!?])\s+/)
    pick = sentences.find { |s| (w = s.split.size).between?(4, 12) } || sentences.max_by { |s| s.length }
    return nil unless pick
    words = pick.split
    words = words.first(12)
    words.join(' ')
  end

  # Convert VTT into a plain text excerpt
  def vtt_to_text(vtt)
    lines = vtt.to_s.each_line.map(&:strip)
    lines.reject { |l| l.empty? || l.include?("-->") || l.start_with?("WEBVTT", "NOTE", "STYLE", "REGION") }.join(' ')
  end
end


