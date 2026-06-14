require 'iso-639'
require_relative '../tts'

class TTS
  class Options
    DEFAULT_VOICE_INSTRUCT = 'female, middle-aged, moderate pitch, english accent'.freeze
    VOICE_KEYS             = %i[voice voice_instruct instruct].freeze
    TEMP_KEYS              = %i[temp temperature].freeze

    def self.for(opts = nil, speaker_wav: nil, lang: 'en')
      new(opts, speaker_wav: speaker_wav, lang: lang).to_h
    end

    def initialize(opts = nil, speaker_wav: nil, lang: 'en')
      @opts        = opts || SymMash.new
      @speaker_wav = speaker_wav
      @lang        = lang.to_s.downcase
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
      normalize(key ? @opts.public_send(key) : default_voice_instruct)
    end

    def default_voice_instruct
      "female, middle-aged, moderate pitch, #{language_name} accent"
    end

    def language_name
      return 'english' if @lang.empty?

      entry = ISO_639.find_by_code(@lang)
      name = entry&.english_name || @lang
      name.to_s.downcase
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
