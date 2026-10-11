module Audiobook
  class Runner
    include Voice
    include SpeechJobs
    include Output

    def initialize(book, stl = nil, opts = nil)
      @book = book
      @lang = book_language
      @stl  = stl
      @opts = opts
    end

    def process_to_audio(out_audio)
      pages = @book.pages
      return create_silent_audiobook(out_audio) if pages.empty?

      @stl&.update "Generating audio"
      final_audio = nil
      Utils::Tmp.dir('audiobook-') do |dir|
        para_offsets = paragraph_offsets(pages)
        total_paras  = para_offsets.last.to_i + pages.last.items.count { |item| item.is_a?(Audiobook::Paragraph) }
        wavs = Array.new(pages.size)
        total_pages = pages.size
        apply_translation!
        speech_options = tts_options(dir)
        prepare_pages(pages, dir, para_offsets, total_paras, total_pages, speech_options)
        if backend_supports?(:batch_synthesis)
          process_speech_jobs(pages, dir, speech_options)
        elsif @book.try(:translation_needed?) && !@book.translated
          @book.translate!
        end

        errors = Queue.new
        pages.each.with_index.peach do |page, idx|
          begin
            wavs[idx] = page.to_wav(dir, page_id(idx), **speech_kwargs(idx, para_offsets, total_paras, total_pages, speech_options))
          rescue => error
            errors << error
          end
        end
        raise errors.pop unless errors.empty?

        # Remove nil entries (empty pages)
        wavs.compact!
        wavs = [create_silent_wav(dir)] if wavs.empty?

        combined_wav = File.join(dir, 'combined.wav')
        @stl&.update 'Concatenating audio'
        Zipper::AudioOps.concat(wavs, combined_wav, stl: @stl)
        add_audio_floor!(combined_wav)

        @stl&.update 'Encoding combined audio'
        final_audio = encode_audio_file(combined_wav, out_audio)
        @stl&.update 'Audiobook ready'
      end
      final_audio
    end
  end
end
