class FFmpeg
  module Builder
    # Tags written to the output.
    module Metadata
      def metadata key = nil, value = nil, stream: nil, index: nil, **entries
        unless entries.empty?
          entries.each_pair { |name, content| metadata name, content, stream: stream, index: index }
          return self
        end

        if key.respond_to? :each_pair
          key.each_pair { |name, content| metadata name, content, stream: stream, index: index }
          return self
        end

        add_operation metadata_option(stream, index), "#{key}=#{value}"
      end

      def metadata_from input
        add_operation '-map_metadata', input
      end

      def metadata_mark value = METADATA_MARK
        metadata :downloaded_with, value
      end

      def metadata_tags entries
        entries.each_pair { |key, value| metadata key, value.to_s.strip }
        self
      end

      def metadata_policy tags: {}, mark: true, source: 0
        metadata_from source
        set_operation [:id3v2], '-id3v2_version', 3
        add_operation '-movflags', 'use_metadata_tags'
        set_operation [:id3v1], '-write_id3v1', 1
        metadata_mark if mark
        metadata_tags tags
      end

      private

      def metadata_option stream, index
        return option_name('metadata', stream) if index.nil?
        raise ArgumentError, 'metadata index requires a stream' if stream.nil?

        "-metadata:#{stream_name stream}:#{index}"
      end
    end
  end
end
