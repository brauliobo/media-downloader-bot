require_relative '../tts'

class TTS
  class Options
    VOICE_KEYS             = %i[voice voice_instruct instruct].freeze
    TEMP_KEYS              = %i[temp temperature].freeze

    def self.for(opts = nil, speaker_wav: nil, lang: nil)
      new(opts, speaker_wav: speaker_wav, lang: lang).to_h
    end

    def initialize(opts = nil, speaker_wav: nil, lang: nil)
      @opts        = opts || SymMash.new
      @speaker_wav = speaker_wav
    end

    def to_h
      {}.tap do |h|
        h[:speed]       = @opts.speed.to_f if speed_supported? && @opts&.speed
        h[:temperature] = temperature if temperature_supported?
        h[:instruct]    = voice_instruct if voice_instruct.present?
        h[:speaker_wav] = @speaker_wav if @speaker_wav.present?
      end
    end

    private

    def speed_supported?
      TTS.supports?(:speech_speed)
    end

    def temperature_supported?
      TTS.supports?(:temperature)
    end

    def temperature
      key = TEMP_KEYS.find { |option| @opts&.public_send(option).present? }
      key ? @opts.public_send(key).to_f : 0
    end

    def voice_instruct
      key = VOICE_KEYS.find { |option| @opts&.public_send(option).present? }
      normalize(@opts.public_send(key)) if key
    end

    def normalize(value)
      value.to_s
        .tr('_', ' ')
        .gsub(/-pitch\b/, ' pitch')
        .gsub(/-accent\b/, ' accent')
        .split(',')
        .map(&:strip)
        .reject(&:empty?)
        .join(', ')
    end
  end
end
