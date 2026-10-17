require 'thread'

module Dubbing
  # Speaks every sentence in its speaker's recorded voice. The reference goes straight to the backend: a synthesized
  # copy of it (an Anchor) would only be a worse clone of the same voice.
  class SpeechSynthesizer
    def initialize(sentences:, references:, opts:, target_lang:, workdir:, video_duration:, stl: nil)
      @sentences       = sentences
      @references      = references
      @opts            = opts
      @target_lang     = target_lang
      @workdir         = workdir
      @video_duration  = video_duration
      @stl             = stl
    end

    def render
      @stl&.update 'dubbing: synthesizing'
      clips         = Array.new(@sentences.size)
      options       = TTS::Options.for(@opts)
      synthesis     = progress_counter('synthesizing')
      normalization = progress_counter('normalizing speech')

      speaker_groups.each do |speaker_id, indices|
        jobs = jobs_for(indices)
        synthesize_jobs(jobs, @references[speaker_id], options, on_batch: synthesis.batch_callback)
        normalize_jobs(jobs, indices, clips, normalization)
      end

      @stl&.update 'dubbing: rendering speech'
      Audio.render_timeline(clips, File.join(@workdir, 'dub.wav'), duration: @video_duration)
    end

    private

    def speaker_groups
      @speaker_groups ||= @sentences.each_index.group_by { |idx| @sentences.fetch(idx).speaker_id }
    end

    def jobs_for(indices)
      indices.map do |idx|
        {
          text:     Text::Spoken::Numbers.call(@sentences.fetch(idx).text, @target_lang),
          lang:     @target_lang,
          out_path: File.join(@workdir, format('sentence-%04d.raw.wav', idx + 1))
        }
      end
    end

    # A speaker without a usable reference gets the backend's default voice.
    def synthesize_jobs(jobs, reference, options, on_batch: nil)
      TTS.synthesize_batch(items: jobs, on_batch: on_batch, **options.merge(reference ? reference.tts_options : {}))
    end

    def normalize_jobs(jobs, indices, clips, progress)
      jobs.zip(indices).each do |job, idx|
        fit = File.join(@workdir, format('sentence-%04d.fit.wav', idx + 1))
        Audio.normalize(job.fetch(:out_path), fit)
        sentence = @sentences.fetch(idx)
        clips[idx] = Audio::Clip.new(
          path: fit, start: sentence.start.to_f, end: sentence.finish.to_f, speaker_id: sentence.speaker_id
        )
        progress.advance
      end
    end

    def progress_counter(operation)
      Utils::ProgressCounter.new(total: @sentences.size, status: @stl) do |completed, total|
        "dubbing: #{operation} #{completed}/#{total}"
      end
    end
  end
end
