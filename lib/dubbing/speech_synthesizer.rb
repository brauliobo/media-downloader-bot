require 'thread'

require_relative '../tts'
require_relative '../tts/options'
require_relative '../utils/progress_counter'
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
      clips             = Array.new(@sentences.size)
      options           = TTS::Options.for(@opts)
      synthesis         = progress_counter('synthesizing')
      normalization     = progress_counter('normalizing speech')
      use_target_voice  = target_reference_supported?

      speaker_groups.each_with_index do |(speaker_id, indices), speaker_index|
        reference = @references.fetch(speaker_id)
        jobs      = jobs_for(indices)
        synthesize_speaker(reference, jobs, speaker_index, options, synthesis.batch_callback, use_target_voice)
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
          text:     @sentences.fetch(idx).text,
          lang:     @target_lang,
          out_path: File.join(@workdir, format('sentence-%04d.raw.wav', idx + 1))
        }
      end
    end

    def synthesize_speaker(reference, jobs, speaker_index, options, on_batch, use_target_voice)
      target_reference = if use_target_voice
        target_reference_for(reference, jobs, speaker_index, options)
      else
        reference
      end

      synthesize_jobs(jobs, target_reference, options, on_batch: on_batch)
    end

    def target_reference_for(reference, jobs, speaker_index, options)
      # Short cross-lingual targets can echo the source-language voice prompt.
      anchor_text = jobs.max_by { |job| job.fetch(:text).to_s.length }.fetch(:text).to_s
      anchor_path = File.join(@workdir, format('speaker-%04d.target-reference.wav', speaker_index))
      anchor_job = {text: anchor_text, lang: @target_lang, out_path: anchor_path}

      synthesize_jobs([anchor_job], reference, options)
      VoiceReference::Reference.new(path: anchor_path, text: anchor_text)
    end

    def synthesize_jobs(jobs, reference, options, on_batch: nil)
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

    def normalize_jobs(jobs, indices, clips, progress)
      jobs.zip(indices).each do |job, idx|
        fit = File.join(@workdir, format('sentence-%04d.fit.wav', idx + 1))
        Audio.normalize(job.fetch(:out_path), fit)
        sentence = @sentences.fetch(idx)
        clips[idx] = Audio::Clip.new(path: fit, start: sentence.start.to_f, end: sentence.end.to_f)
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
