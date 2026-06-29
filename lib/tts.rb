require_relative 'tts/piper'
require_relative 'tts/coqui_tts'
require_relative 'tts/outetts'
require_relative 'tts/omni_voice'

class TTS
  BACKEND = const_get(ENV['TTS'] || 'OmniVoice')
  INTERNAL_OPTIONS = %i[tts_batch_size].freeze
  DEFAULT_SAMPLE_RATE = 22_050

  def self.synthesize(**args)
    args = public_args(args)
    BACKEND.synthesize(**args)
  end

  def self.synthesize_batch(items:, **args)
    return [] if items.empty?

    batch_size = args.delete(:tts_batch_size).to_i
    batch_size = items.size if batch_size <= 0
    shared_args = public_args(args)

    items.each_slice(batch_size).flat_map do |batch|
      if supports?(:batch_synthesis) && BACKEND.respond_to?(:synthesize_batch)
        BACKEND.synthesize_batch(items: batch, **shared_args)
      else
        batch.map { |item| synthesize(**shared_args.merge(item)) }
      end
    end
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

  def self.public_args(args)
    args = args.dup
    INTERNAL_OPTIONS.each { |key| args.delete(key) }
    args
  end

  def self.backend_sample_rate
    BACKEND.output_sample_rate if BACKEND.respond_to?(:output_sample_rate)
  end
end
