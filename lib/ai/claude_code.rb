require 'json'
require 'open3'

module AI
  class ClaudeCode
    MODEL = ENV['CLAUDE_SHORTS_MODEL'] || 'sonnet'

    def self.prompt(text, model: MODEL)
      out, err, st = Open3.capture3('claude', '--model', model, '-p', text)
      raise "claude failed (#{st.exitstatus}): #{err}" unless st.success?
      out.strip
    end

    def self.json_prompt(text, model: MODEL)
      raw = prompt(text, model: model)
      # strip markdown fences if present
      raw = raw.gsub(/```json\s*/i, '').gsub(/```\s*/, '')
      JSON.parse(raw)
    end
  end
end
