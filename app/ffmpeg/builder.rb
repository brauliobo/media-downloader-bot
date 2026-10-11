class FFmpeg
  # The command line being built: inputs, the output, and the options set between them.
  module Builder
    include Filtering
    include Streams
    include Encoding
    include Metadata
    include Runs

    def input source, format: nil, safe: nil, seek: nil, duration: nil, sample_rate: nil,
              channels: nil, channel_layout: nil, cuda: false, keyframes_only: false
      arguments = []
      arguments.concat ['-hwaccel', 'cuda'] if cuda
      arguments.concat ['-skip_frame', 'nokey'] if keyframes_only
      arguments.concat ['-f', format.to_s] if format
      arguments.concat ['-safe', boolean_value(safe)] unless safe.nil?
      arguments.concat ['-ss', seek.to_s] unless seek.nil?
      arguments.concat ['-t', duration.to_s] unless duration.nil?
      arguments.concat ['-ar', sample_rate.to_i.to_s] unless sample_rate.nil?
      arguments.concat ['-ac', channels.to_i.to_s] unless channels.nil?
      arguments.concat ['-channel_layout', channel_layout.to_s] if channel_layout
      @inputs << [*arguments, '-i', source.to_s]
      self
    end

    def seek value
      set_operation [:seek], '-ss', value
    end

    def duration value
      set_operation [:duration], '-t', value
    end

    def end_at value
      set_operation [:end_at], '-to', value
    end

    def format name
      set_operation [:format], '-f', name
    end

    def movflags value
      set_operation [:movflags], '-movflags', value
    end

    def cuda decode: false, encode: false
      @cuda_decode = decode
      @cuda_encode = encode
      self
    end

    def overwrite
      set_global [:overwrite], '-y'
    end

    def threads value
      set_global [:threads], '-threads', value.to_i
    end

    def loglevel value
      set_global [:loglevel], '-loglevel', value
    end

    def hide_banner
      set_global [:hide_banner], '-hide_banner'
    end

    def no_stats
      set_global [:no_stats], '-nostats'
    end

    def output destination
      raise ArgumentError, 'output already set' if @output_set

      @output     = destination
      @output_set = true
      self
    end

    def capture
      raise ArgumentError, 'output is required' unless @output_set

      @runner.call command
    ensure
      reset!
    end

    def run! label: 'ffmpeg failed'
      raise ArgumentError, 'output is required' unless @output_set

      destination = @output
      stdout, stderr, status = @runner.call command
      file = destination unless destination == :stdout
      Sh.assert_success! label, stderr, status: status, output: file
      destination == :stdout ? stdout : destination
    ensure
      reset!
    end

    private

    def reset!
      @global_options = []
      @inputs         = []
      @operations     = []
      @filters        = Hash.new { |filters, stream| filters[stream] = [] }
      @cuda_decode    = false
      @cuda_encode    = false
      @output         = nil
      @output_set     = false
      apply_profile
    end

    def apply_profile
      profile = PROFILES.fetch @profile
      profile.each do |option|
        case option
        when :overwrite   then overwrite
        when :threads     then threads @default_threads
        when :loglevel    then loglevel :error
        when :hide_banner then hide_banner
        when :no_stats    then no_stats
        end
      end
    end

    def command
      [
        @ffmpeg,
        *@global_options.flat_map { |option| option[:arguments] },
        *(['-hwaccel', 'cuda'] if @cuda_decode),
        *@inputs.flatten,
        *@operations.flat_map { |operation| operation_arguments operation },
        output_argument
      ].compact
    end

    def output_argument
      @output == :stdout ? '-' : @output.to_s
    end

    def flag_arguments flag, value
      value.nil? ? [flag] : [flag, value.to_s]
    end

    def add_operation flag, value = nil
      @operations << {arguments: flag_arguments(flag, value)}
      self
    end

    def set_operation key, flag, value = nil
      set_semantic_operation key, arguments: flag_arguments(flag, value)
    end

    def set_global key, flag, value = nil
      arguments = flag_arguments flag, value
      option = @global_options.find { |entry| entry[:key] == key }
      if option
        option[:arguments] = arguments
      else
        @global_options << {key: key, arguments: arguments}
      end
      self
    end

    def set_semantic_operation key, attributes
      operation = @operations.find { |entry| entry[:key] == key }
      if operation
        operation.replace key: key, **attributes
      else
        @operations << {key: key, **attributes}
      end
      self
    end

    def operation_arguments operation
      case operation[:kind]
      when :filter
        filters = @filters.fetch operation[:stream]
        ["-#{operation[:stream]}f", filters.join(',')]
      when :quality
        mode = operation[:mode] == :auto ? (@cuda_encode ? :cq : :crf) : operation[:mode]
        ["-#{mode}", operation[:value].to_s]
      else
        operation[:arguments]
      end
    end

    def stream_name stream
      return nil if stream.nil?

      STREAMS.fetch stream.to_sym, stream.to_s.sub(/\A:/, '')
    end

    def option_name name, stream
      suffix = stream_name stream
      suffix ? "-#{name}:#{suffix}" : "-#{name}"
    end

    def boolean_value value
      value ? '1' : '0'
    end
  end
end
