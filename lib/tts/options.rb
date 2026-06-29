require_relative '../tts'

class TTS
  class Options
    VOICE_KEYS             = %i[voice voice_instruct instruct].freeze
    TEMP_KEYS              = %i[temp temperature].freeze
    BATCH_SIZE_KEYS        = %i[tts_batch_size batch_size].freeze
    BATCH_KEYS             = %i[tts_batch batch].freeze
    DEFAULT_BATCH_SIZE     = 100

    def self.for(opts = nil, speaker_wav: nil, lang: nil)
      new(opts, speaker_wav: speaker_wav, lang: lang).to_h
    end

    def initialize(opts = nil, speaker_wav: nil, lang: nil)
      @opts        = opts || SymMash.new
      @speaker_wav = speaker_wav
    end

    def to_h
      {}.tap do |h|
        h[:temperature]    = temperature if temperature_supported?
        h[:tts_batch_size] = batch_size if batch_size
        h[:instruct]       = voice_instruct if voice_instruct.present?
        h[:speaker_wav]    = @speaker_wav if @speaker_wav.present?
      end
    end

    private

    def temperature_supported?
      TTS.supports?(:temperature)
    end

    def temperature
      key = TEMP_KEYS.find { |option| @opts&.public_send(option).present? }
      key ? @opts.public_send(key).to_f : 0
    end

    def batch_size
      return unless batch_enabled?

      key = BATCH_SIZE_KEYS.find { |option| @opts&.public_send(option).present? }
      value = key ? @opts.public_send(key).to_i : ENV['TTS_BATCH_SIZE'].to_i
      value = DEFAULT_BATCH_SIZE if value <= 0
      value if value > 1
    end

    def batch_enabled?
      key = BATCH_KEYS.find { |option| @opts&.public_send(option).present? }
      return truthy?(@opts.public_send(key)) if key

      truthy?(ENV['TTS_BATCH'])
    end

    def truthy?(value)
      value.to_s.strip.downcase.in?(%w[1 true yes on])
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
        .gsub(/\bmedium pitch\b/, 'moderate pitch')
        .split(',')
        .map(&:strip)
        .reject(&:empty?)
        .join(', ')
    end
  end
end
