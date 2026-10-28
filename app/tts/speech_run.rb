class TTS
  # Speaks jobs, each translated first when there is a translate step: the translations run ahead of the speech, so a
  # batch is spoken as soon as its texts are ready. A job with a :reference is spoken in that voice.
  class SpeechRun
    TRANSLATION_TASKS = 2

    # translate gets a job and fills in its :text; a text left blank (the translator had nothing to say) is not spoken.
    # on_batch gets each batch once spoken, before it is counted.
    def initialize(jobs, status: nil, prefix: nil, translate: nil, on_batch: nil)
      @jobs        = jobs
      @translate   = translate
      @on_batch    = on_batch
      @translation = Utils::ProgressCounter.new(total: jobs.size)
      @progress    = Utils::ProgressCounter.new(total: jobs.size, status: status) { |done, total| "#{prefix}#{report(done, total)}" }
    end

    def call(**options)
      return speak(@jobs, options) unless @translate

      Pipeline.each(@jobs, tasks: TRANSLATION_TASKS, batch: BATCH_SIZE, perform: method(:translate)) do |batch|
        speak(batch.select { |job| job[:text].present? }, options)
      end
    end

    private

    def translate(job) = @translate.call(job).tap { @translation.advance }

    def speak(jobs, options)
      jobs.group_by { |job| job[:reference] }.each do |reference, group|
        TTS.synthesize_batch(items: group, on_batch: method(:spoken).to_proc, **options.merge(reference&.tts_options || {}))
      end
    end

    def spoken(batch)
      @on_batch&.call(batch)
      @progress.batch_callback.call(batch)
    end

    # Translated alongside the speech, so the translation shows with the audio count that reports it.
    def report(done, total)
      [@jobs[done - 1][:status], ("translated #{@translation.count}/#{total}" if @translation.count.positive?), "audio #{done}/#{total}"].compact.join(', ')
    end
  end
end
