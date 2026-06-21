require_relative 'utils/sh'

module Prober

  PROBE_CMD = "ffprobe -v quiet -print_format json -show_format -show_streams %{file}"

  def self.for file
    probe, err, status = Sh.run(PROBE_CMD % {file: Sh.escape(file)})
    Sh.assert_success!("ffprobe failed for #{File.basename(file)}", err, status: status)

    raise "ffprobe returned no output for #{File.basename(file)}" if probe.to_s.strip.empty?

    probe = JSON.parse probe
    probe = SymMash.new probe
  end

end
