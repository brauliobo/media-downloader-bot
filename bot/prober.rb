class Bot
  class Prober

    PROBE_CMD = "ffprobe -v quiet -print_format json -show_format -show_streams %{file}"

    def self.for file
      probe = `#{PROBE_CMD % {file: Shellwords.escape(file)}}`
      raise 'probe failed' if probe.blank?
      probe = JSON.parse probe
      probe = SymMash.new probe
    end

  end
end
