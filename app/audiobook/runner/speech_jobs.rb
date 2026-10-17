module Audiobook
  class Runner
    # The pages read aloud: their speech jobs, translated where the book is, run through the TTS pipeline.
    module SpeechJobs
      private

      def paragraph_offsets(pages)
        offset = 0
        pages.map do |page|
          offset.tap { offset += page.items.count { |item| item.is_a?(Audiobook::Paragraph) } }
        end
      end

      def prepare_pages(pages, dir, para_offsets, total_paras, total_pages, speech_options)
        pages.each.with_index do |page, idx|
          page.prepare_speech_items(dir, page_id(idx), **speech_kwargs(idx, para_offsets, total_paras, total_pages, speech_options))
        end
      end

      def speech_kwargs(idx, para_offsets, total_paras, total_pages, speech_options)
        {
          lang: @lang, stl: @stl,
          para_context: { current: para_offsets[idx], total: total_paras },
          page_context: { current: idx + 1, total: total_pages },
          book_metadata: @book.metadata,
          tts_options: speech_options,
        }
      end

      def apply_translation!
        @lang = @book.speech_language if @book.try(:translation_needed?)
      end

      def process_speech_jobs(pages, dir, speech_options, lang = @lang)
        jobs = pages.each_with_index.flat_map do |page, idx|
          page.speech_jobs(dir, page_id(idx), lang)
        end
        return if jobs.empty?

        speed, options = AudioFiles.split_speed_options(speech_options)
        progress = Utils::ProgressCounter.new(total: jobs.size, status: @stl) do |completed, total|
          "#{jobs[completed - 1][:status]}, audio #{completed}/#{total}"
        end
        synthesize_speech_jobs(jobs, options, store_batch(progress, speed))
      end

      # Each batch is stored (at the speed asked) as it arrives, so the wavs do not pile up while the book is read.
      def store_batch(progress, speed)
        lambda do |batch|
          AudioFiles.compress_all(batch.map { |job| job[:out_path] }, speed)
          progress.batch_callback.call(batch)
        end
      end

      def synthesize_speech_jobs(jobs, options, on_batch)
        if @book.try(:translation_needed?) && !@book.translated
          pipeline_speech_jobs(jobs, options, on_batch)
        else
          TTS.synthesize_batch(items: jobs, on_batch: on_batch, **options)
        end
      end

      def pipeline_speech_jobs(jobs, options, on_batch)
        target = @book.speech_language
        Pipeline.each(
          jobs, tasks: 2, batch: TTS::BATCH_SIZE,
          perform: ->(job) { translate_speech_job(job, target) }
        ) do |batch|
          TTS.synthesize_batch(items: batch.select { |job| job[:text].present? }, on_batch: on_batch, **options)
        end
        @book.translate!
      end

      # The translation can come back blank or as punctuation only, which the TTS refuses: such a job is skipped, as an untranslated one is.
      def translate_speech_job(job, target)
        sent = job[:sentence]
        Book.translate_sentences([sent], from: sent.language.presence || book_language, to: target)
        job[:text] = sent.spoken_text
        job[:lang] = sent.language
        job
      end

      def audio_speed
        speed = @opts&.speed
        return unless speed

        speed = speed.to_f
        speed if speed.positive? && speed != 1
      end

      def book_language
        Audiobook.book_language(@book)
      end

      def page_id(idx) = format('%04d', idx + 1)
    end
  end
end
