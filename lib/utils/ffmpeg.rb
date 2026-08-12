require 'open3'
require 'rubygems/version'

module Utils
  module FFmpeg
    MIN_VERSION = Gem::Version.new('9.0')
    BINARIES    = %w[ffmpeg ffprobe].freeze

    module_function

    def verify!(runner: Open3.method(:capture3))
      BINARIES.each do |binary|
        stdout, stderr, status = runner.call(binary, '-version')
        output = "#{stdout}\n#{stderr}"
        raise "#{binary} is required" unless status.success?

        version = output[/\A#{binary} version n?(\d+(?:\.\d+)+)/, 1]
        raise "unable to determine #{binary} version" unless version
        next if Gem::Version.new(version) >= MIN_VERSION

        raise "#{binary} #{MIN_VERSION} or newer is required; found #{version}"
      rescue Errno::ENOENT
        raise "#{binary} is required"
      end
    end
  end
end
