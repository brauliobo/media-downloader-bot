require 'thread'

require_relative '../tts'
require_relative '../tts/options'
require_relative 'audio'

module Dubbing
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
      clips = Array.new(@sentences.size)
      on_batch = progress_callback

      speaker_groups.each_with_index do |(speaker_id, indices), speaker_index|
        reference = @references.fetch(speaker_id)
        jobs      = jobs_for(indices)
        synthesize_speaker(reference, jobs, speaker_index, on_batch)
        normalize_jobs(jobs, indices, clips)
      end

      Audio.render_timeline(clips, File.join(@workdir, 'dub.wav'), duration: @video_duration)
    end

    private

    def speaker_groups
      @speaker_groups ||= @sentences.each_index.group_by { |idx| @sentences.fetch(idx).speaker_id }
    end

    def jobs_for(indices)
      indices.map do |idx|
        {
          text:     @sentences.fetch(idx).text,
          lang:     @target_lang,
          out_path: File.join(@workdir, format('sentence-%04d.raw.wav', idx + 1))
        }
      end
    end

    def synthesize_speaker(reference, jobs, speaker_index, on_batch)
      options = TTS::Options.for(@opts)
      return synthesize_direct(reference, jobs, options, on_batch) unless target_reference_supported?

      # Short cross-lingual targets can echo the source-language voice prompt.
      anchor_text = jobs.max_by { |job| job.fetch(:text).to_s.length }.fetch(:text).to_s
      anchor_path = File.join(@workdir, format('speaker-%04d.target-reference.wav', speaker_index))
      anchor_job = {text: anchor_text, lang: @target_lang, out_path: anchor_path}
      source_options = options.merge(reference.tts_options)

      TTS.synthesize_batch(items: [anchor_job], threads: 1, **source_options)

      target_options = options.merge(speaker_wav: anchor_path, ref_text: anchor_text)
      TTS.synthesize_batch(items: jobs, on_batch: on_batch, threads: 1, **target_options)
    end

    def synthesize_direct(reference, jobs, options, on_batch)
      TTS.synthesize_batch(
        items:    jobs,
        on_batch: on_batch,
        threads:  1,
        **options.merge(reference.tts_options)
      )
    end

    def target_reference_supported?
      TTS.supports?(:stable_voice_reference) && TTS.supports?(:batch_synthesis)
    end

    def normalize_jobs(jobs, indices, clips)
      jobs.zip(indices).each do |job, idx|
        fit = File.join(@workdir, format('sentence-%04d.fit.wav', idx + 1))
        Audio.normalize(job.fetch(:out_path), fit)
        sentence = @sentences.fetch(idx)
        clips[idx] = Audio::Clip.new(path: fit, start: sentence.start.to_f, end: sentence.end.to_f)
      end
    end

    def progress_callback
      completed = 0
      mutex = Mutex.new
      lambda do |batch|
        mutex.synchronize do
          completed += batch.size
          @stl&.update "dubbing: synthesizing #{completed}/#{@sentences.size}"
        end
      end
    end
  end
end
