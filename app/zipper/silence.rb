class Zipper
  # Silent audio: a file of it, and the pauses between speech, made once per shape and reused.
  module Silence
    DEFAULT_SAMPLE_RATE = 22_050
    CHANNEL_LAYOUTS     = { 1 => 'mono', 2 => 'stereo' }.freeze
    CACHE               = {}
    CACHE_MUTEX         = Mutex.new

    module_function

    def file(path, seconds, sample_rate: DEFAULT_SAMPLE_RATE, format: nil, amplitude: nil, ffmpeg: nil, ffmpeg_factory: nil)
      format = normalize_format format
      sample_rate = format[:sample_rate].to_i if format[:sample_rate].to_i.positive?
      channels = format[:channels].to_i
      layout = format[:channel_layout].to_s
      layout = channel_layout_for channels if layout.empty?

      encoding = FFmpeg.pause_encoding format
      FFmpeg.resolve(ffmpeg, ffmpeg_factory).create_silence(
        output:             path,
        source_sample_rate: sample_rate,
        duration:            seconds,
        filter:              amplitude.to_f.positive? ? FFmpeg.lowpass_filter(6000) : nil,
        sample_rate:         format.empty? ? nil : sample_rate,
        channels:             format.empty? || !channels.positive? ? nil : channels,
        channel_layout:       format.empty? ? nil : layout,
        amplitude:             amplitude,
        codec:                 encoding.codec,
        codec_profile:        encoding.profile,
        bitrate:               encoding.bitrate,
        sample_format:        encoding.sample_format,
        label:                 'Failed to create silent audio file'
      )
      path
    end

    def pause(seconds, dir, sample_rate: nil, extension: '.wav', format: nil, amplitude: nil, ffmpeg: nil, ffmpeg_factory: nil)
      return nil if seconds.to_f <= 0

      key = seconds.to_f.round 3
      sample_rate = (sample_rate || DEFAULT_SAMPLE_RATE).to_i
      extension = ".#{extension}" unless extension.start_with? '.'
      raise ArgumentError, "invalid audio extension: #{extension}" unless extension.match?(/\A\.[a-z0-9]+\z/i)

      format = normalize_format format
      sample_rate = format[:sample_rate].to_i if format[:sample_rate].to_i.positive?
      format[:sample_rate] = sample_rate unless format.empty?
      format_key = format_digest format
      format_suffix = format_key ? "_#{format_key}" : ''
      amplitude_key = amplitude.to_f.positive? ? "_#{amplitude.to_f.to_s.tr '.', '_'}" : ''
      cache_key = "#{dir}:#{key}:#{sample_rate}:#{extension}:#{format_suffix}:#{amplitude_key}"
      pause_file = File.join dir, "pause_#{key.to_s.gsub '.', '_'}_#{sample_rate}#{format_suffix}#{amplitude_key}#{extension}"

      cached cache_key, pause_file do
        file pause_file, key, sample_rate: sample_rate, format: format, amplitude: amplitude,
             ffmpeg: ffmpeg, ffmpeg_factory: ffmpeg_factory
      end
    end

    def normalize_format(format) = format ? format.to_h.transform_keys(&:to_sym) : {}

    def format_digest(format)
      return if format.empty?

      serialized = format.sort_by { |key, _value| key.to_s }.to_h
      Digest::SHA256.hexdigest(JSON.generate serialized)[0, 12]
    end

    def channel_layout_for(channels) = CHANNEL_LAYOUTS[channels.to_i] || 'mono'

    def cached(cache_key, path)
      CACHE_MUTEX.synchronize do
        CACHE[cache_key] ||= begin
          yield unless File.exist? path
          path
        end
      end
    end
  end
end
