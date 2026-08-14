require_relative '../utils/safety'

class FFmpeg
  module Filters
    extend self

    def scale_filter width:, modulus: 2
      "scale=#{width}:trunc(ow/a/#{modulus})*#{modulus}"
    end

    def preserve_resolution_scale_filter modulus: 2
      "scale=trunc(iw/#{modulus})*#{modulus}:trunc(ih/#{modulus})*#{modulus}"
    end

    def decimate_filter settings = nil
      return 'mpdecimate' if settings.nil? || settings == true

      "mpdecimate=#{Utils::Safety.safe_filter settings}"
    end

    def speed_filter value, stream:
      stream = stream.to_s.sub(/\A:/, '')
      stream = {audio: 'a', video: 'v'}.fetch stream.to_sym, stream
      stream == 'v' ? "setpts=PTS/#{value}" : "atempo=#{value}"
    end

    def time_ranges_expression ranges
      ranges.intervals.map do |interval|
        "between(t\\,#{time_value interval.start}\\,#{time_value interval.finish})"
      end.join '+'
    end

    def cut_filters ranges, video:, audio:
      expression = "not(#{time_ranges_expression ranges})"
      {
        video: video ? ["select='#{expression}'", 'setpts=N/FRAME_RATE/TB'] : [],
        audio: audio ? ["aselect='#{expression}'", 'asetpts=N/SR/TB'] : [],
      }
    end

    def silence_filter ranges
      "volume=0:enable='#{time_ranges_expression ranges}'"
    end

    def voice_quality_filter
      VOICE_QUALITY_FILTER
    end

    def speech_cleanup_filter
      SPEECH_CLEANUP_FILTER
    end

    def silence_source sample_rate:, channel_layout:
      "anullsrc=channel_layout=#{channel_layout}:sample_rate=#{sample_rate}"
    end

    def noise_source amplitude:, sample_rate:
      "anoisesrc=color=white:amplitude=#{amplitude}:sample_rate=#{sample_rate}"
    end

    def format_filter pixel_format
      "format=#{pixel_format}"
    end

    def lowpass_filter frequency
      "lowpass=f=#{frequency}"
    end

    def audio_floor_source amplitude:, sample_rate:
      noise_source amplitude: amplitude, sample_rate: sample_rate
    end

    def speech_speed_filter speed
      "rubberband=tempo=#{speed}:pitch=1:transients=smooth:detector=soft:phase=laminar:" \
        'window=long:formant=preserved'
    end

    def atempo_chain speed
      remaining = speed.to_f
      factors = []
      while remaining > 2.0
        factors << 2.0
        remaining /= 2.0
      end
      factors << remaining unless remaining == 1.0
      factors.map { |factor| speed_filter format('%.6f', factor), stream: :audio }.join ','
    end

    def dub_timeline_filter clips:, duration:
      chains = clips.map.with_index do |clip, idx|
        delay = (clip.start.to_f * 1000).round
        speed = clip.speed == 1.0 ? '' : "#{atempo_chain clip.speed},"
        "[#{idx}:a]#{speed}adelay=#{delay}:all=1[a#{idx}]"
      end
      mix_inputs = clips.each_index.map { |idx| "[a#{idx}]" }.join
      "#{chains.join ';'};#{mix_inputs}amix=inputs=#{clips.size}:normalize=0," \
        "loudnorm=I=-18:TP=-1.5:LRA=7,atrim=0:#{duration}"
    end

    def dub_audio_mix_filter duration:
      '[1:a]aformat=sample_rates=48000:channel_layouts=stereo[speech];' \
        '[2:a]aformat=sample_rates=48000:channel_layouts=stereo[bed];' \
        "[speech][bed]amix=inputs=2:normalize=0,alimiter=limit=0.95,atrim=0:#{duration}[a]"
    end

    def audio_floor_filter loudness_lufs:
      "[0:a]loudnorm=I=#{loudness_lufs}:TP=-2:LRA=11[speech];[1:a]#{lowpass_filter 6000}[floor];" \
        '[speech][floor]amix=inputs=2:duration=first:dropout_transition=0:normalize=0,' \
        'alimiter=limit=0.841395:attack=5:release=50:level=false'
    end

    def voice_reference_filter profile, silence_threshold_db:, pad_duration: nil
      base = {
        raw:     nil,
        clone:   ['highpass=f=80', 'afftdn=nf=-25', 'loudnorm=I=-16:TP=-1.5:LRA=11'].join(','),
        quality: [voice_quality_filter, edge_filter(silence_threshold_db)].join(','),
      }.fetch profile.to_sym
      filter = [base, ("apad=pad_dur=#{pad_duration}" if pad_duration)].compact.join ','
      filter.empty? ? nil : filter.freeze
    end

    def subtitle_ass_filter path
      escaped_path = path.to_s.gsub('\\', '\\\\').gsub(':', '\\:').gsub(',', '\\,').gsub("'", "\\'")
      "ass=#{escaped_path}"
    end

    private

    def edge_filter silence_threshold_db
      [
        "silenceremove=start_periods=1:start_duration=0.1:start_threshold=#{silence_threshold_db}dB:start_silence=0.05",
        'areverse',
        "silenceremove=start_periods=1:start_duration=0.1:start_threshold=#{silence_threshold_db}dB:start_silence=0.05",
        'afade=t=in:st=0:d=0.05',
        'areverse',
        'afade=t=in:st=0:d=0.03',
      ].join ','
    end

    def time_value value
      return value.to_i.to_s if value.to_i == value

      format('%.3f', value).sub(/0+\z/, '').delete_suffix '.'
    end
  end

  extend Filters
end
