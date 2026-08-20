require 'tmpdir'
require_relative 'audio_files'
require_relative 'pauses'
require_relative '../zipper'
require_relative '../tts/options'
require_relative '../language'
require_relative '../voice_reference'
require_relative '../utils/progress_counter'
require_relative '../pipeline'

module Audiobook
  class Runner
    VOICE_REFERENCE_TEXT  = Language::REF_FALLBACK
    VOICE_REFERENCE_WORDS = 12..24
    VOICE_REFERENCE_MAX_CHARS = 240

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
        Zipper.concat_audio(wavs, combined_wav, stl: @stl)
        add_audio_floor!(combined_wav)

        @stl&.update 'Encoding combined audio'
        final_audio = encode_audio_file(combined_wav, out_audio)
        @stl&.update 'Audiobook ready'
      end
      final_audio
    end

    private

    def add_audio_floor!(wav_path)
      amplitude = @opts&.audio_floor_amplitude.to_f
      return wav_path unless amplitude.positive?

      Zipper.add_audio_floor!(
        wav_path,
        amplitude: amplitude,
        loudness_lufs: @opts&.audio_loudness_lufs.to_f,
        sample_rate: AudioFiles.sample_rate
      )
    end

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
      AudioFiles.silence(silent_wav, Pauses::EMPTY_BOOK)
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
      options = TTS::Options.for(tts_config)
      if @opts&.position_temperature.present?
        options[:position_temperature] = @opts.position_temperature.to_f
      end
      options[:audio_speed] = audio_speed if audio_speed
      return options unless stable_voice_reference?

      if voice_url
        ref_path  = File.join(dir, 'audiobook_voice_reference.wav')
        reference_options = {
          url:              voice_url,
          output:           ref_path,
          language:         @lang,
          reference_filter: :clone,
        }
        reference_options[:on_status] = @stl.method(:update) if @stl
        reference = ::VoiceReference.from_url(**reference_options)
        return with_speaker(options, ref_path, reference.text)
      end

      if @opts&.speaker_wav.present?
        return with_speaker(options, File.expand_path(@opts.speaker_wav), @opts.ref_text.to_s.strip)
      end

      options[:instruct] ||= detected_voice_instruct
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

      with_speaker(options, ref_path, voice_reference_text)
    end

    def with_speaker(options, wav, text)
      options.merge(speaker_wav: wav, ref_text: text)
    end

    def page_id(idx) = format('%04d', idx + 1)

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
      synthesize_speech_jobs(jobs, options, progress)
      AudioFiles.speed_all(jobs.map { |job| job[:out_path] }, speed)
    end

    def synthesize_speech_jobs(jobs, options, progress)
      if @book.try(:translation_needed?) && !@book.translated
        pipeline_speech_jobs(jobs, options, progress)
      else
        TTS.synthesize_batch(items: jobs, on_batch: progress.batch_callback, **options)
      end
    end

    def pipeline_speech_jobs(jobs, options, progress)
      target = @book.speech_language
      Pipeline.each(
        jobs, tasks: 2, batch: TTS::BATCH_SIZE,
        perform: ->(job) { translate_speech_job(job, target) }
      ) do |batch|
        TTS.synthesize_batch(items: batch, on_batch: progress.batch_callback, **options)
      end
      @book.translate!
    end

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

    def voice_reference_text
      @voice_reference_text ||= source_voice_reference_text || Language.voice_reference_text(@lang)
    end

    def source_voice_reference_text
      return if @book.try(:translation_needed?) && !@book.translated

      @book.pages.flat_map(&:all_sentences).filter_map do |sentence|
        text = sentence.text.to_s.strip
        words = text.split
        next unless VOICE_REFERENCE_WORDS.cover?(words.size)
        next if text.length > VOICE_REFERENCE_MAX_CHARS

        text
      end.max_by { |text| text.split.size }
    end

    def detected_voice_instruct
      return if voice_instruct.present?

      "#{author_gender}, middle-aged, moderate pitch"
    end

    def author_gender
      @author_gender ||= @book.try(:author_gender).presence || 'male'
    end

    def stable_voice_reference?
      backend_supports?(:stable_voice_reference)
    end

    def backend_supports?(feature)
      TTS.supports?(feature)
    end

    def voice_instruct
      TTS::Options.for(tts_config)[:instruct].to_s
    end

    def voice_url
      value = @opts&.voice.to_s.strip
      value if value.match?(%r{\Ahttps?://}i)
    end

    def tts_config
      return @opts unless voice_url

      SymMash.new(@opts).tap { |options| options.delete(:voice) }
    end
  end
end
