require 'open3'
require 'tempfile'

module AI
  class Codex
    extend JSONPrompt

    MODEL = ENV['CODEX_SHORTS_MODEL']

    def self.prompt(text, model: MODEL, effort: nil)
      Tempfile.create('codex-response') do |out_file|
        cmd = [
          'codex', 'exec',
          '--sandbox', 'read-only',
          '-c', 'approval_policy=never',
          '--ephemeral',
          '--skip-git-repo-check',
          '--color', 'never',
          '-o', out_file.path
        ]
        cmd += ['--model', model] unless model.to_s.strip.empty?
        cmd += ['-c', "model_reasoning_effort=#{effort}"] unless effort.to_s.strip.empty?
        cmd << '-'

        env = ENV.to_h
        env['CODEX_HOME'] = File.join(Dir.home, '.codex') if env['CODEX_HOME'].to_s.empty?
        _out, err, st = Open3.capture3(env, *cmd, stdin_data: text)
        raise "codex failed (#{st.exitstatus}): #{err}" unless st.success?

        out_file.rewind
        out_file.read.strip
      end
    end
  end
end
