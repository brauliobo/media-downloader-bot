require 'open3'
require_relative 'json_prompt'

module AI
  class ClaudeCode
    extend JSONPrompt

    MODEL = ENV['CLAUDE_SHORTS_MODEL'] || 'sonnet'

    def self.prompt(text, model: MODEL)
      out, err, st = Open3.capture3('claude', '--model', model, '-p', text)
      raise "claude failed (#{st.exitstatus}): #{err}" unless st.success?
      out.strip
    end
  end
end
