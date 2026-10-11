class FFmpeg
  module Operations
    # Building and mixing the audio of a dubbed video.
    module Dubbing
      def normalize_dub_audio input:, output:, label:
        run_one_shot label: label do |builder|
          builder.input input
          builder.channels 1
          builder.sample_rate 48_000
          builder.output output
        end
      end

      # Mixing every clip in one graph outgrows the argument and open-file limits, so clips are mixed in batches.
      def render_dub_timeline clips:, duration:, output:, label:
        Utils::Tmp.dir('dub-timeline-') do |dir|
          clips = mix_dub_batches clips, Utils::Tmp.dir('batches-', dir), label while clips.size > DUB_MIX_BATCH
          mix_dub_clips clips, FFmpeg.dub_timeline_filter(clips: clips, duration: duration), output, label, dir
        end
      end

      def create_dub_silence output:, duration:, label:
        run_one_shot label: label do |builder|
          source = FFmpeg.silence_source sample_rate: 48_000, channel_layout: :mono
          builder.input source, format: :lavfi
          builder.duration duration.to_f
          builder.output output
        end
      end

      def mux_dubbed_audio video:, speech:, non_vocals:, output:, duration:, label:, filter: nil
        filter ||= FFmpeg.dub_audio_mix_filter duration: duration

        run_one_shot label: label do |builder|
          builder.input video
          builder.input speech
          builder.input non_vocals
          builder.set_complex_filter filter
          builder.map_stream :video
          builder.map_filter 'a'
          builder.duration duration
          builder.copy stream: :video
          builder.codec 'aac', stream: :audio
          builder.bitrate 128, stream: :audio
          builder.output output
        end
      end

      private

      def mix_dub_batches clips, dir, label
        clips.each_slice(DUB_MIX_BATCH).with_index.map do |batch, index|
          offset = batch.map(&:start).min
          path   = File.join dir, "#{index}.wav"
          mix_dub_clips batch, FFmpeg.dub_mix_filter(clips: batch, offset: offset), path, label, dir, codec: 'pcm_f32le'
          MixedDubClip.new path: path, start: offset
        end
      end

      # The graph goes through a file: one chain per clip would still overflow a single argument.
      def mix_dub_clips clips, filter, output, label, dir, codec: nil
        script = File.join dir, 'filter.txt'
        File.write script, filter

        run_one_shot label: label do |builder|
          clips.each { |clip| builder.input clip.path }
          builder.set_complex_filter_script script
          builder.codec codec, stream: :audio if codec
          builder.channels 1
          builder.sample_rate 48_000
          builder.output output
        end
      end
    end
  end
end
