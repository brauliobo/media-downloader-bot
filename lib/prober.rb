require 'json'
require_relative 'utils/sh'

module Prober

  PROBE_CMD = "ffprobe -v quiet -print_format json -show_format -show_streams %{file}"
  AUDIO_FORMAT_FIELDS = %i[
    codec_name profile codec_tag_string mime_codec_string sample_fmt sample_rate channels channel_layout
    bits_per_sample extradata_size bit_rate
  ].freeze
  AUDIO_SIGNATURE_FIELDS = %i[
    codec_name profile codec_tag_string mime_codec_string sample_fmt sample_rate channels channel_layout
    bits_per_sample extradata_size
  ].freeze
  AUDIO_INTEGER_FIELDS = %i[sample_rate channels bits_per_sample extradata_size bit_rate].freeze

  def self.for file
    probe, err, status = Sh.run(PROBE_CMD % {file: Sh.escape(file)})
    Sh.assert_success!("ffprobe failed for #{File.basename(file)}", err, status: status)

    raise "ffprobe returned no output for #{File.basename(file)}" if probe.to_s.strip.empty?

    probe = JSON.parse probe
    probe = SymMash.new probe
  end

  def self.audio_stream(file)
    stream = Array(self.for(file).streams).find { |candidate| candidate.codec_type.to_s == 'audio' }
    raise "ffprobe found no audio stream for #{File.basename(file)}" unless stream

    stream
  end

  def self.audio_format(file)
    stream = audio_stream(file)
    AUDIO_FORMAT_FIELDS.each_with_object({}) do |field, format|
      value = stream[field]
      format[field] = AUDIO_INTEGER_FIELDS.include?(field) ? value.to_i : value.to_s
    end
  end

  def self.audio_signature(file)
    format = audio_format(file)
    AUDIO_SIGNATURE_FIELDS.each_with_object({}) do |field, signature|
      signature[field] = format.fetch(field)
    end
  end

end
