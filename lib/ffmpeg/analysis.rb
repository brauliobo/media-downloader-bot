class FFmpeg
  def probe path
    one_shot do
      label = "ffprobe failed for #{File.basename path}"
      output = run_probe(
        ['-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams', path],
        label: label
      )
      raise "ffprobe returned no output for #{File.basename path}" if output.to_s.strip.empty?

      JSON.parse output
    end
  end

  def encoder_available? name
    one_shot do
      stdout, _, status = @runner.call [@ffmpeg, '-encoders']
      status.success? && stdout.lines.any? { |line| line.split[1] == name }
    end
  end

  def analyze_audio path, kind:, silence_threshold_db: nil
    one_shot do
      expression, label = audio_analysis kind, silence_threshold_db
      builder = fresh profile: :analysis
      builder.input path
      builder.set_filter expression, stream: :audio
      builder.format :null
      builder.output :stdout
      stdout, stderr, status = builder.capture
      Sh.assert_success! label, stderr, status: status
      [stdout, stderr]
    end
  end

  def audio_duration path
    one_shot do
      stdout = run_probe(
        [
          '-v', 'error', '-show_entries', 'format=duration',
          '-of', 'default=noprint_wrappers=1:nokey=1', path
        ],
        label: 'audio duration analysis failed'
      )
      stdout.to_f
    end
  end

  public :probe, :encoder_available?, :analyze_audio, :audio_duration
end
