class TTS
  # Speaks jobs, each translated first when there is a translate step: the translations run ahead of the speech, so a
  # batch is spoken as soon as its texts are ready. A job with a :reference is spoken in that voice.
  class SpeechRun
    # translate gets a job and fills in its :text; a text left blank (the translator had nothing to say) is not spoken.
    # on_batch gets each batch once spoken, before it is counted. `resumed` is how many an earlier run already spoke: the counts
    # are those of the whole job, not of the jobs left.
    def initialize(jobs, resumed: 0, status: nil, prefix: nil, translate: nil, on_batch: nil)
      @jobs        = jobs
      @resumed     = resumed
      @translate   = translate
      @on_batch    = on_batch
      @translation = Utils::ProgressCounter.new(total: jobs.size + resumed, done: resumed)
      @progress    = Utils::ProgressCounter.new(total: jobs.size + resumed, done: resumed, status: status) { |done, total| "#{prefix}#{report(done, total)}" }
    end

    # Translation and speech each run on all the threads the job has (two for an admin), they are not split between them.
    def call(**options)
      return speak(@jobs, options) unless @translate

      Pipeline.each(@jobs, tasks: 1, batch: BATCH_SIZE, perform: method(:translate)) do |batch|
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
      [@jobs[done - @resumed - 1][:status], ("translated #{@translation.count}/#{total}" if @translation.count > @resumed), "audio #{done}/#{total}"].compact.join(', ')
    end
  end
end
