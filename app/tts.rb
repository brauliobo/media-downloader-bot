class TTS
  BACKEND = const_get(ENV['TTS'] || 'OmniVoice')
  BATCH_SIZE = 2
  DEFAULT_SAMPLE_RATE = 22_050
  # The share of batches that may stay silent after their retries: a fragment is sometimes not spoken, a broken backend never is.
  # A job of a few batches (a short clip, the candidates of a voice) cannot tell the two apart, so it may leave this many silent.
  MAX_SILENT = 0.25
  MIN_SILENT_ALLOWED = 2
  SILENT_TRIES = 3

  def self.synthesize(**args)
    BACKEND.synthesize(**args)
  end

  def self.synthesize_batch(items:, on_batch: nil, threads: nil, **args)
    batches = items.each_slice(BATCH_SIZE).to_a
    errors = Queue.new
    silent = Queue.new

    process_batch = lambda do |batch|
      begin
        speak_batch(batch, **args)
      rescue Audible::Silent => error
        silent << error
      end
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
    raise silent.pop if silent.size > [batches.size * MAX_SILENT, MIN_SILENT_ALLOWED].max

    items.map { |item| item.fetch(:out_path) }
  end

  # The backend answered, so a silent batch is tried again at once; a backend that is down backs off instead.
  def self.speak_batch(batch, **args)
    Utils::Retry.call(tries: SILENT_TRIES, sleep: false, on: Audible::Silent) do
      Utils::Retry.tts(retry_if: ->(error) { !error.is_a?(Audible::Silent) }) { BACKEND.synthesize_batch(items: batch, **args) }
    end
  end
  private_class_method :speak_batch

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
