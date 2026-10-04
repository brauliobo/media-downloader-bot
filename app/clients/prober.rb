module Prober

  AUDIO_FORMAT_FIELDS = %i[
    codec_name profile codec_tag_string mime_codec_string sample_fmt sample_rate channels channel_layout
    bits_per_sample extradata_size bit_rate
  ].freeze
  AUDIO_SIGNATURE_FIELDS = %i[
    codec_name profile codec_tag_string mime_codec_string sample_fmt sample_rate channels channel_layout
    bits_per_sample extradata_size
  ].freeze
  AUDIO_INTEGER_FIELDS = %i[sample_rate channels bits_per_sample extradata_size bit_rate].freeze

  def self.for file, ffmpeg: FFmpeg.new
    probe = ffmpeg.probe file
    SymMash.new probe
  end

  # The same two questions are asked of a probe all over the codebase.
  def self.video_stream(probe) = Array(probe&.streams).find { |stream| stream.codec_type.to_s == 'video' }
  def self.audio_stream?(probe) = Array(probe&.streams).any? { |stream| stream.codec_type.to_s == 'audio' }
  def self.video_stream?(probe) = !video_stream(probe).nil?

  def self.audio_stream file, ffmpeg: FFmpeg.new
    probe  = self.for file, ffmpeg: ffmpeg
    stream = Array(probe.streams).find { |candidate| candidate.codec_type.to_s == 'audio' }
    raise "ffprobe found no audio stream for #{File.basename(file)}" unless stream

    stream
  end

  def self.audio_format file, ffmpeg: FFmpeg.new
    stream = audio_stream file, ffmpeg: ffmpeg
    AUDIO_FORMAT_FIELDS.each_with_object({}) do |field, format|
      value = stream[field]
      format[field] = AUDIO_INTEGER_FIELDS.include?(field) ? value.to_i : value.to_s
    end
  end

  def self.audio_signature file, ffmpeg: FFmpeg.new
    format = audio_format file, ffmpeg: ffmpeg
    AUDIO_SIGNATURE_FIELDS.each_with_object({}) do |field, signature|
      signature[field] = format.fetch(field)
    end
  end

end
