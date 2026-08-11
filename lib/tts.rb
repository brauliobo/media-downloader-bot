require 'retriable'

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
  BATCH_SIZE = 2
  DEFAULT_SAMPLE_RATE = 22_050

  def self.synthesize(**args)
    BACKEND.synthesize(**args)
  end

  def self.synthesize_batch(items:, on_batch: nil, threads: nil, **args)
    chinese = items.any? { |item| (item[:lang] || item['lang'] || args[:lang]).to_s == 'zh' }
    batch_size = chinese ? 1 : BATCH_SIZE
    batches = items.each_slice(batch_size).to_a
    errors = Queue.new

    process_batch = lambda do |batch|
      Retriable.retriable(tries: 4, base_interval: 0.5, multiplier: 2.0) do
        BACKEND.synthesize_batch(items: batch, **args)
      end
      on_batch&.call(batch)
    rescue StandardError => error
      errors << error
    end

    batches.peach(threads: threads, &process_batch)

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
