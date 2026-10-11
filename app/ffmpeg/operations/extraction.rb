class FFmpeg
  module Operations
    # Pulling audio, speech and subtitles out of a media file.
    module Extraction
      def extract_audio input:, output:, sample_rate:, channels:, label:, start: nil, duration: nil,
                        filter: nil, filter_profile: nil, silence_threshold_db: nil,
                        pad_duration: nil, codec: 'pcm_s16le'
        filter = FFmpeg.voice_reference_filter filter_profile,
                                               silence_threshold_db: silence_threshold_db,
                                               pad_duration: pad_duration if filter.nil? && filter_profile

        run_one_shot profile: :extract, label: label do |builder|
          builder.input input, seek: start, duration: duration
          builder.disable :video
          builder.add_filter filter, stream: :audio if filter
          builder.channels channels
          builder.sample_rate sample_rate
          builder.codec codec, stream: :audio
          builder.output output
        end
      end

      def extract_speech_ranges input:, output:, ranges:, sample_rate:, channels:, label:
        chunks = ranges.intervals.each_slice(Filters::MAX_SELECT_TERMS).to_a
        return extract_speech_range_chunk(input:, output:, ranges:, sample_rate:, channels:, label:) if chunks.size <= 1

        Utils::Tmp.dir('speech-ranges-') do |dir|
          parts = chunks.map.with_index do |intervals, index|
            part = File.join dir, "#{index}.wav"
            extract_speech_range_chunk(
              input:, output: part, sample_rate:, channels:, label:,
              ranges: Utils::TimeRanges.new(intervals, option: :vad)
            )
            part
          end
          list = File.join dir, 'concat.txt'
          File.write list, parts.map { |path| Utils::Safety.concat_manifest_path path }.join("\n")
          concat_audio inputs: list, output:, copy: true, label:
        end
        output
      end

      def transcribe_wav input:, output:, label:
        run_one_shot profile: :overwrite, label: label do |builder|
          builder.input input
          builder.sample_rate 16_000
          builder.channels 1
          builder.codec 'pcm_s16le', stream: :audio
          builder.output output
        end
      end

      def convert_subtitle input:, format:, label:, stream_index: nil
        run_one_shot label: label do |builder|
          builder.input input
          builder.map_stream :subtitle, index: stream_index unless stream_index.nil?
          builder.codec 'webvtt', stream: :subtitle if %i[vtt webvtt].include? format.to_sym
          builder.format format.to_sym == :vtt ? :webvtt : format
          builder.output :stdout
        end
      end

      def remux_audio input:, output:, label:
        run_one_shot profile: :overwrite, label: label do |builder|
          builder.input input
          builder.map_stream :audio
          builder.copy stream: :audio
          builder.movflags '+faststart'
          builder.format :mp4
          builder.output output
        end
      end

      def extract_copy_audio input:, output:, label:
        run_one_shot profile: :extract, label: label do |builder|
          builder.input input
          builder.disable :video
          builder.copy stream: :audio
          builder.output output
        end
      end

      private

      def extract_speech_range_chunk input:, output:, ranges:, sample_rate:, channels:, label:
        run_one_shot profile: :extract, label: label do |builder|
          builder.input input
          builder.disable :video
          builder.select_intervals FFmpeg.time_ranges_expression(ranges), stream: :audio
          builder.channels channels
          builder.sample_rate sample_rate
          builder.codec 'pcm_s16le', stream: :audio
          builder.output output
        end
      end
    end
  end
end
