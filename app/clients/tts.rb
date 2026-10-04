class TTS
  BACKEND = const_get(ENV['TTS'] || 'OmniVoice')
  BATCH_SIZE = 2
  DEFAULT_SAMPLE_RATE = 22_050

  def self.synthesize(**args)
    BACKEND.synthesize(**args)
  end

  def self.synthesize_batch(items:, on_batch: nil, threads: nil, **args)
    batches = items.each_slice(BATCH_SIZE).to_a
    errors = Queue.new

    process_batch = lambda do |batch|
      Utils::Retry.tts { BACKEND.synthesize_batch(items: batch, **args) }
      on_batch&.call(batch)
    rescue StandardError => error
      errors << error
    end

    if threads
      Enumerable.with_peach_threads(threads) { batches.peach(threads: threads, &process_batch) }
    else
      batches.peach(&process_batch)
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
