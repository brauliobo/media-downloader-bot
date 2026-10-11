class FFmpeg
  module Builder
    # Which streams are mapped or dropped, and the codec, rate and layout each is written with.
    module Streams
      def add_map selector
        add_operation '-map', selector
      end

      def map_stream stream, input: 0, index: 0
        add_map "#{input}:#{stream_name stream}:#{index}"
      end

      def map_filter label
        label = label.to_s
        add_map label.start_with?('[') ? label : "[#{label}]"
      end

      def codec name, stream: nil
        set_operation [:codec, stream_name(stream)], option_name('c', stream), name
      end

      def subtitle_codec
        codec SUBTITLE_CODEC, stream: :subtitle
      end

      def copy stream: nil
        codec 'copy', stream: stream
      end

      def copy_audio
        copy stream: :audio
      end

      def no_audio
        disable :audio
      end

      def disable stream
        key = [:disable, stream_name(stream)]
        flag = {
          'a' => '-an',
          'v' => '-vn',
          's' => '-sn',
          'd' => '-dn'
        }.fetch stream_name(stream)
        if @inputs.empty?
          set_global key, flag
        else
          set_operation key, flag
        end
      end

      def bitrate value, stream:, unit: :kbit
        stream = stream_name stream
        set_operation [:bitrate, stream], option_name('b', stream), rate_value(value, unit)
      end

      def sample_rate value, stream: nil
        set_operation [:sample_rate, stream_name(stream)], option_name('ar', stream), value.to_i
      end

      def frame_rate value, stream: nil
        set_operation [:frame_rate, stream_name(stream)], option_name('r', stream), value
      end

      def frame_rate_mode value, stream: nil
        set_operation [:frame_rate_mode, stream_name(stream)], option_name('fps_mode', stream), value
      end

      def channels value, stream: nil
        set_operation [:channels, stream_name(stream)], option_name('ac', stream), value.to_i
      end

      def channel_layout value, stream: nil
        set_operation [:channel_layout, stream_name(stream)], option_name('channel_layout', stream), value
      end

      def sample_format value, stream: nil
        set_operation [:sample_format, stream_name(stream)], option_name('sample_fmt', stream), value
      end

      def codec_profile name, stream:
        stream = stream_name stream
        set_operation [:codec_profile, stream], option_name('profile', stream), name
      end

      def average_bitrate enabled = true
        set_operation [:average_bitrate], '-abr', boolean_value(enabled)
      end

      def variable_bitrate value
        set_operation [:variable_bitrate], '-vbr', value
      end

      def maxrate value, stream: nil
        set_operation [:maxrate, stream_name(stream)], option_name('maxrate', stream), value
      end

      def buffer_size value, stream: nil
        set_operation [:buffer_size, stream_name(stream)], option_name('bufsize', stream), value
      end

      def rate_control value, stream: nil
        set_operation [:rate_control, stream_name(stream)], option_name('rc', stream), value
      end

      private

      def rate_value value, unit
        suffix = {bit: '', kbit: 'k', mbit: 'M'}.fetch unit.to_sym
        "#{value}#{suffix}"
      end
    end
  end
end
