require_relative 'tts/piper'
require_relative 'tts/chatterbox'
require_relative 'tts/coqui_tts'
require_relative 'tts/f5_tts'
require_relative 'tts/fish_speech'
require_relative 'tts/outetts'
require_relative 'tts/omni_voice'
require_relative 'tts/moss_tts'

class TTS
  BACKEND = const_get(ENV['TTS'] || 'OmniVoice')
  BATCH_SIZE = 4
  DEFAULT_SAMPLE_RATE = 22_050

  def self.synthesize(**args)
    BACKEND.synthesize(**args)
  end

  def self.synthesize_batch(items:, **args)
    batches = items.each_slice(BATCH_SIZE).to_a
    errors = Queue.new

    batches.peach do |batch|
      BACKEND.synthesize_batch(items: batch, **args)
    rescue => error
      errors << error
    end

    raise errors.pop unless errors.empty?

    items.map { |item| item.fetch(:out_path) }
  end

  def self.supports?(feature)
    BACKEND.respond_to?(predicate = :"supports_#{feature}?") && BACKEND.public_send(predicate)
  end

  def self.output_sample_rate
    env_sample_rate('TTS_SAMPLE_RATE') || backend_sample_rate || DEFAULT_SAMPLE_RATE
  end

  def self.env_sample_rate(name)
    ENV[name].to_i.then { |rate| rate if rate.positive? }
  end

  def self.backend_sample_rate
    BACKEND.output_sample_rate if BACKEND.respond_to?(:output_sample_rate)
  end
end
