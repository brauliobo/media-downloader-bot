require 'json'
require 'open3'
require_relative 'json_schema'

module AI
  class OpenCode
    MODEL     = ENV['OPENCODE_MODEL'] || ENV['OPENCODE_SHORTS_MODEL']
    CLEAN_ENV = {
      'OPENCODE'                                  => nil,
      'OPENCODE_PID'                              => nil,
      'OPENCODE_PURE'                             => nil,
      'OPENCODE_SERVER_USERNAME'                  => nil,
      'OPENCODE_SERVER_PASSWORD'                  => nil,
      'OPENCODE_DISABLE_FFF'                      => nil,
      'OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER' => nil
    }.freeze

    def self.prompt(text, model: MODEL)
      cmd = ['opencode', 'run', '--pure', '--log-level', 'ERROR']
      cmd += ['--model', model] unless model.to_s.strip.empty?
      cmd << text

      out, err, st = Open3.capture3(CLEAN_ENV, *cmd)
      raise "opencode failed (#{st.exitstatus}): #{err}" unless st.success?

      out.strip
    end

    def self.json_prompt(text, schema:, model: MODEL)
      raw = prompt(text, model: model)
      AI::JSONSchema.parse(raw, schema: schema)
    end
  end
end
