require 'json'
require 'open3'
require 'tempfile'

module AI
  class Codex
    MODEL = ENV['CODEX_SHORTS_MODEL']

    def self.prompt(text, model: MODEL)
      Tempfile.create('codex-response') do |out_file|
        cmd = [
          'codex', 'exec',
          '--sandbox', 'read-only',
          '--ask-for-approval', 'never',
          '--ephemeral',
          '--skip-git-repo-check',
          '--color', 'never',
          '-o', out_file.path
        ]
        cmd += ['--model', model] unless model.to_s.strip.empty?
        cmd << '-'

        _out, err, st = Open3.capture3(*cmd, stdin_data: text)
        raise "codex failed (#{st.exitstatus}): #{err}" unless st.success?

        out_file.rewind
        out_file.read.strip
      end
    end

    def self.json_prompt(text, model: MODEL)
      raw = prompt(text, model: model)
      raw = raw.gsub(/```json\s*/i, '').gsub(/```\s*/, '')
      JSON.parse(raw)
    end
  end
end
