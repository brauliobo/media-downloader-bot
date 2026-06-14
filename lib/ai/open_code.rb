require 'json'
require 'open3'
require_relative 'json_schema'

module AI
  class OpenCode
    MODEL = ENV['OPENCODE_MODEL'] || ENV['OPENCODE_SHORTS_MODEL']

    def self.prompt(text, model: MODEL)
      cmd = ['opencode', 'run', '--pure', '--log-level', 'ERROR']
      cmd += ['--model', model] unless model.to_s.strip.empty?
      cmd << text

      out, err, st = Open3.capture3(*cmd)
      raise "opencode failed (#{st.exitstatus}): #{err}" unless st.success?

      out.strip
    end

    def self.json_prompt(text, schema:, model: MODEL)
      raw = prompt(text, model: model)
      AI::JSONSchema.parse(raw, schema: schema)
    end
  end
end
