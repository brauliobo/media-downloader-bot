class FFmpeg
  module Analysis
    # The filter that measures each kind, and what to say when it fails.
    AUDIO_ANALYSES = {
      signal:       ['astats=metadata=0:reset=0', 'audio signal analysis failed'],
      frame_signal: ['astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-',
                     'audio frame signal analysis failed'],
      loudness:     ['ebur128=peak=true', 'audio loudness analysis failed'],
      silence:      ['silencedetect=noise=%<db>sdB:d=0.08', 'audio silence analysis failed']
    }.freeze

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
        expression, label = AUDIO_ANALYSES.fetch(kind)
        expression %= { db: silence_threshold_db }
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
end
