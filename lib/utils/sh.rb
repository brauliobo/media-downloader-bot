require 'open3'
require 'shellwords'

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
    cmd.is_a?(Array) ? Open3.capture3(*cmd, *args, **params) : Open3.capture3(cmd, *args, **params)
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
