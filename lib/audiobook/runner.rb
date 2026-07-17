require 'tmpdir'
require_relative 'audio_files'
require_relative '../zipper'
require_relative '../tts/options'
require_relative '../language'

module Audiobook
  class Runner
    VOICE_REFERENCE_TEXT = Language::REF_FALLBACK
    AUTHOR_SAMPLE_PAGES  = 3

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
      Dir.mktmpdir do |dir|
        # Precompute per-page paragraph offsets to keep numbering while parallelizing pages
        para_counts  = pages.map { |p| p.items.count { |i| i.is_a?(Audiobook::Paragraph) } }
        total_paras  = para_counts.sum
        para_offsets = []
        run = 0
        para_counts.each { |c| para_offsets << run; run += c }

        wavs = Array.new(pages.size)
        total_pages = pages.size
        speech_options = tts_options(dir)
        prepare_pages(pages, dir, para_offsets, total_paras, total_pages, speech_options)
        batch_synthesize_pages(pages, dir, speech_options)

        errors = Queue.new
        pages.each.with_index.peach do |page, idx|
          begin
            wavs[idx] = page.to_wav(
              dir, format('%04d', idx + 1),
              lang: @lang, stl: @stl,
              para_context: { current: para_offsets[idx], total: total_paras },
              page_context: { current: idx + 1, total: total_pages },
              book_metadata: @book.metadata,
              tts_options: speech_options
            )
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
        Zipper.concat_audio(wavs, combined_wav, stl: @stl)

        @stl&.update 'Encoding combined audio'
        final_audio = encode_audio_file(combined_wav, out_audio)
        @stl&.update 'Audiobook ready'
      end
      final_audio
    end

    private

    def create_silent_audiobook(out_audio)
      @stl&.update 'No text found anywhere - creating silent audio file'

      final_audio = nil
      Dir.mktmpdir do |dir|
        silent_wav = create_silent_wav(dir)
        final_audio = encode_audio_file(silent_wav, out_audio) if File.exist?(silent_wav)
      end

      @stl&.update 'Silent audiobook created (no text found)'
      final_audio
    end

    def create_silent_wav(dir)
      silent_wav = File.join(dir, 'silent.wav')
      AudioFiles.silence(silent_wav, 1)
    end

    def encode_audio_file(input_wav, out_audio)
      zip_opts = SymMash.new(@opts || {})
      zip_opts.delete(:speed)
      # Pick format based on requested extension; default to opus
      requested_ext = File.extname(out_audio.to_s).downcase
      case requested_ext
      when '.m4a', '.aac'
        zip_opts.format = Zipper::Types.audio.aac
      when '.mp3'
        zip_opts.format = Zipper::Types.audio.mp3
      else
        zip_opts.format = Zipper::Types.audio.opus
      end
      zip_opts.bitrate ||= 32
      zip_opts.speech_cleanup = true
      target = out_audio.to_s
      zip_opts.skip_metamark = true
      Zipper.zip_audio(input_wav, target, opts: zip_opts)
      target
    end

    def tts_options(dir)
      options = TTS::Options.for(@opts, lang: @lang)
      options[:audio_speed] = audio_speed if audio_speed
      options[:instruct] ||= detected_voice_instruct if stable_voice_reference?
      return options unless stable_voice_reference?

      ref_path = File.join(dir, 'audiobook_voice_reference.wav')
      reference_options = options.except(:audio_speed)
      unless File.exist?(ref_path) && File.size?(ref_path)
        TTS.synthesize(
          text:     voice_reference_text,
          lang:     @lang,
          out_path: ref_path,
          **reference_options
        )
      end

      options.merge(speaker_wav: ref_path, ref_text: voice_reference_text)
    end

    def prepare_pages(pages, dir, para_offsets, total_paras, total_pages, speech_options)
      pages.each.with_index do |page, idx|
        page.prepare_speech_items(
          dir, format('%04d', idx + 1),
          lang: @lang,
          stl: @stl,
          para_context: { current: para_offsets[idx], total: total_paras },
          page_context: { current: idx + 1, total: total_pages },
          book_metadata: @book.metadata,
          tts_options: speech_options
        )
      end
    end

    def batch_synthesize_pages(pages, dir, speech_options)
      return unless speech_options[:tts_batch_size].to_i > 1

      jobs = pages.each_with_index.flat_map do |page, idx|
        page.speech_jobs(dir, format('%04d', idx + 1), @lang)
      end
      return if jobs.empty?

      speed, options = AudioFiles.split_speed_options(speech_options)
      TTS.synthesize_batch(items: jobs, **options)
      AudioFiles.speed_all(jobs.map { |job| job[:out_path] }, speed)
    end

    def audio_speed
      speed = @opts&.speed
      return unless speed

      speed = speed.to_f
      speed if speed.positive? && speed != 1
    end

    def book_language
      metadata = @book.metadata || {}
      language = metadata['language'] || metadata[:language]
      language ||= metadata.language if metadata.respond_to?(:language)
      (language || 'en').to_s
    end

    def voice_reference_text
      @voice_reference_text ||= Language.voice_reference_text(@lang)
    end

    def detected_voice_instruct
      return if voice_instruct.present?

      "#{author_gender}, middle-aged, moderate pitch"
    end

    def author_gender
      @author_gender ||= Language.author_gender(author_gender_input)
    end

    def author_gender_input
      metadata = @book.metadata || {}
      sample = @book.pages.first(AUTHOR_SAMPLE_PAGES).flat_map(&:all_sentences)
        .map(&:text).join("\n")
      ["Metadata:\n#{metadata.to_h}", "First pages:\n#{sample}"].join("\n\n")
    end

    def stable_voice_reference?
      backend_supports?(:stable_voice_reference)
    end

    def backend_supports?(feature)
      TTS.supports?(feature)
    end

    def voice_instruct
      TTS::Options.for(@opts, lang: @lang)[:instruct].to_s
    end
  end
end
