require 'open3'
require 'shellwords'
require 'timeout'

class Sh

  class Error < RuntimeError
    attr_reader :label, :stderr, :status

    def initialize(label, stderr, status: nil)
      @label  = label
      @stderr = stderr
      @status = status
      super Sh.failure_message(label, stderr, status: status)
    end

    def user_message
      message
    end
  end

  def self.escape f
    Shellwords.escape f
  end

  def self.run cmd, *args, **params
    STDERR.puts(printable(cmd)) if ENV['PRINT_CMD']
    timeout = params.delete(:timeout) || ENV.fetch('COMMAND_TIMEOUT', 7_200).to_f
    unless timeout.positive?
      return cmd.is_a?(Array) ? Open3.capture3(*cmd, *args, **params) : Open3.capture3(cmd, *args, **params)
    end

    command = cmd.is_a?(Array) ? [*cmd, *args] : [cmd, *args]
    stdin_data = params.delete(:stdin_data)
    Open3.popen3(*command, **params.merge(pgroup: true)) do |stdin, stdout, stderr, wait|
      stdin.write(stdin_data) if stdin_data
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }

      begin
        result = Timeout.timeout(timeout) do
          status = wait.value
          [out_reader.value, err_reader.value, status]
        end
      rescue Timeout::Error
        terminate_group(wait.pid)
        raise Error.new('command timed out', printable(cmd))
      end

      result
    end
  end

  def self.terminate_group(pid)
    Process.kill('KILL', -pid)
  rescue Errno::ESRCH
    nil
  ensure
    Process.wait(pid) rescue nil
  end

  def self.error_message(stderr, status: nil, fallback: 'command failed')
    msg = stderr.to_s.strip
    return msg unless msg.empty?

    code = status.respond_to?(:exitstatus) ? status.exitstatus : status
    [fallback, code].compact.join(': ')
  end

  def self.failure_message(label, stderr, status: nil)
    "#{label}: #{error_message(stderr, status: status)}"
  end

  def self.assert_success!(label, stderr, status:, output: nil)
    ok = status.success?
    ok &&= File.exist?(output) if output
    raise Error.new(label, stderr, status: status) unless ok
  end

  def self.printable(cmd)
    cmd.is_a?(Array) ? cmd.map { |part| escape(part.to_s) }.join(' ') : cmd
  end

end
