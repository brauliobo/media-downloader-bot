require 'open3'
require 'shellwords'

class Sh

  def self.escape f
    Shellwords.escape f
  end

  def self.run cmd, *args, **params
    STDERR.puts(printable(cmd)) if ENV['PRINT_CMD']
    cmd.is_a?(Array) ? Open3.capture3(*cmd, *args, **params) : Open3.capture3(cmd, *args, **params)
  end

  def self.printable(cmd)
    cmd.is_a?(Array) ? cmd.map { |part| escape(part.to_s) }.join(' ') : cmd
  end

end

