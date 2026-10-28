module Dubbing
  # Speaks every sentence in its speaker's recorded voice, translating them on the way when given a translate step. The
  # reference goes straight to the backend: a synthesized copy of it (an Anchor) would only be a worse clone of the same voice.
  class SpeechSynthesizer
    # The sentences spoken: those the translation left with nothing to say are dropped.
    attr_reader :sentences

    # translate gets a sentence and returns the text to speak for it.
    def initialize(sentences:, references:, opts:, target_lang:, workdir:, video_duration:, translate: nil, stl: nil)
      @sentences       = sentences
      @references      = references
      @opts            = opts
      @target_lang     = target_lang
      @workdir         = workdir
      @video_duration  = video_duration
      @translate       = translate
      @stl             = stl
    end

    def render
      @stl&.update 'dubbing: synthesizing'
      jobs = @sentences.each_with_index.map { |sentence, idx| job_for(sentence, idx) }
      # A speaker without a usable reference gets the backend's default voice.
      TTS::SpeechRun.new(jobs, status: @stl, prefix: 'dubbing: ', translate: (method(:translate_job) if @translate)).call(**TTS::Options.for(@opts))

      jobs = jobs.select { |job| job[:text].present? }
      @sentences = jobs.map { |job| job.fetch(:sentence) }
      clips = normalize_jobs(jobs)

      @stl&.update 'dubbing: rendering speech'
      Audio.render_timeline(clips, File.join(@workdir, 'dub.wav'), duration: @video_duration)
    end

    private

    def job_for(sentence, idx)
      {
        sentence:  sentence,
        text:      spoken_text(sentence.text),
        lang:      @target_lang,
        reference: @references[sentence.speaker_id],
        out_path:  File.join(@workdir, format('sentence-%04d.raw.wav', idx + 1))
      }
    end

    def translate_job(job) = job.tap { job[:text] = spoken_text(@translate.call(job.fetch(:sentence))) }

    def spoken_text(text) = Text::Spoken::Numbers.call(text, @target_lang)

    def normalize_jobs(jobs)
      progress = Utils::ProgressCounter.new(total: jobs.size, status: @stl) { |done, total| "dubbing: normalizing speech #{done}/#{total}" }
      jobs.each_with_index.map do |job, idx|
        fit = File.join(@workdir, format('sentence-%04d.fit.wav', idx + 1))
        Audio.normalize(job.fetch(:out_path), fit)
        sentence = job.fetch(:sentence)
        Audio::Clip.new(path: fit, start: sentence.start.to_f, end: sentence.finish.to_f, speaker_id: sentence.speaker_id).tap { progress.advance }
      end
    end
  end
end
