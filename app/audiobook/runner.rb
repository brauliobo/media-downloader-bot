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

      @stl&.update 'Generating audio'
      Utils::Tmp.dir('audiobook-') do |dir|
        combined_wav = File.join(dir, 'combined.wav')
        @stl&.update 'Concatenating audio'
        Zipper::AudioOps.concat(synthesize_pages(pages, dir), combined_wav, stl: @stl)
        add_audio_floor!(combined_wav)

        @stl&.update 'Encoding combined audio'
        encode_audio_file(combined_wav, out_audio).tap { @stl&.update 'Audiobook ready' }
      end
    end

    private

    def synthesize_pages(pages, dir)
      para_offsets = paragraph_offsets(pages)
      total_paras  = para_offsets.last.to_i + pages.last.items.count { |item| item.is_a?(Audiobook::Paragraph) }
      apply_translation!
      speech_options = tts_options(dir)
      prepare_pages(pages, dir, para_offsets, total_paras, pages.size, speech_options)
      translate_or_batch(pages, dir, speech_options)

      wavs = render_pages(pages, dir, para_offsets, total_paras, speech_options)
      wavs.empty? ? [create_silent_wav(dir)] : wavs
    end

    def translate_or_batch(pages, dir, speech_options)
      if backend_supports?(:batch_synthesis)
        process_speech_jobs(pages, dir, speech_options)
      elsif @book.try(:translation_needed?) && !@book.translated
        @book.translate!
      end
    end

    # Pages with nothing to say come back empty and are left out.
    def render_pages(pages, dir, para_offsets, total_paras, speech_options)
      errors = Queue.new
      wavs   = Array.new(pages.size)
      pages.each.with_index.peach do |page, idx|
        wavs[idx] = page.to_wav(dir, page_id(idx), **speech_kwargs(idx, para_offsets, total_paras, pages.size, speech_options))
      rescue => error
        errors << error
      end
      raise errors.pop unless errors.empty?

      wavs.compact
    end
  end
end
