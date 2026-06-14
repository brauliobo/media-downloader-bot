require 'json'
require 'open3'
require_relative 'json_schema'

module AI
  class ClaudeCode
    MODEL = ENV['CLAUDE_SHORTS_MODEL'] || 'sonnet'

    def self.prompt(text, model: MODEL)
      out, err, st = Open3.capture3('claude', '--model', model, '-p', text)
      raise "claude failed (#{st.exitstatus}): #{err}" unless st.success?
      out.strip
    end

    def self.json_prompt(text, schema:, model: MODEL)
      raw = prompt(text, model: model)
      AI::JSONSchema.parse(raw, schema: schema)
    end
  end
end
