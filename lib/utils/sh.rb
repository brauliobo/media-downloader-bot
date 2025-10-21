require 'open3'

class Sh

  def self.escape f
    Shellwords.escape f
  end

  def self.run cmd, *args, **params
    STDERR.puts cmd if ENV['PRINT_CMD']
    Open3.capture3 cmd, *args, **params
  end

end


