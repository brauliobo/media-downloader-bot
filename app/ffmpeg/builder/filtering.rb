class FFmpeg
  module Builder
    # Filter expressions on the streams, and the intervals cut, kept or silenced with them.
    module Filtering
      def add_filter expression, stream:
        stream = stream_name stream
        @filters[stream] << expression.to_s
        add_filter_operation stream
        self
      end

      def preserve_resolution_scale modulus: 2
        add_filter FFmpeg.preserve_resolution_scale_filter(modulus: modulus), stream: :video
      end

      def decimate settings = nil
        add_filter FFmpeg.decimate_filter(settings), stream: :video
      end

      def speed_video value
        add_filter FFmpeg.speed_filter(value, stream: :video), stream: :video
      end

      def speed_audio_filter value
        add_filter FFmpeg.speed_filter(value, stream: :audio), stream: :audio
      end

      def speed value, stream:
        stream_name(stream) == 'v' ? speed_video(value) : speed_audio_filter(value)
      end

      def scale width:, modulus: 2
        add_filter FFmpeg.scale_filter(width: width, modulus: modulus), stream: :video
      end

      def select_intervals expression, stream:, negate: false
        stream     = stream_name stream
        expression = "not(#{expression})" if negate
        filter     = stream == 'v' ? 'select' : 'aselect'
        timestamps = stream == 'v' ? 'setpts=N/FRAME_RATE/TB' : 'asetpts=N/SR/TB'
        add_filter "#{filter}='#{expression}'", stream: stream
        add_filter timestamps, stream: stream
      end

      def cut_intervals expression, video:, audio:
        select_intervals expression, stream: :video, negate: true if video
        select_intervals expression, stream: :audio, negate: true if audio
        self
      end

      def silence_intervals expression
        add_filter "volume=0:enable='#{expression}'", stream: :audio
      end

      def set_filter expression, stream:
        stream = stream_name stream
        @filters[stream] = [expression.to_s]
        add_filter_operation stream
        self
      end

      def clear_filters stream = nil
        streams = stream ? [stream_name(stream)] : @filters.keys
        streams.each do |name|
          @filters.delete name
          @operations.reject! { |operation| operation[:key] == [:filter, name] }
        end
        self
      end

      def set_complex_filter expression
        set_operation [:complex_filter], '-filter_complex', expression
      end

      def set_complex_filter_script path
        set_operation [:complex_filter], '-/filter_complex', path
      end

      private

      def add_filter_operation stream
        return if @operations.any? { |operation| operation[:key] == [:filter, stream] }

        @operations << {key: [:filter, stream], kind: :filter, stream: stream}
      end
    end
  end
end
