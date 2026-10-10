module FFmpegDouble
  def ffmpeg_double result: ['', '', nil]
    ffmpeg = instance_double FFmpeg
    methods = %i[
      input seek probe disable output_frame_rate output_sample_rate output_channels frame_rate_mode
      add_filter add_map map_stream scale preserve_resolution_scale metadata codec encode_video maxrate buffer_size
      rate_control bitrate no_audio copy_audio encode_audio metadata_policy movflags
      end_at duration output capture create_silence concat_audio add_audio_floor speed_audio
      audio_to_wav extract_copy_audio convert_subtitle subtitle_codec
    ]
    methods.each { |method| allow(ffmpeg).to receive(method) }
    allow(ffmpeg).to receive(:capture).and_return result
    ffmpeg
  end
end
