require 'tmpdir'
require_relative '../zipper'

module Audiobook
  class Runner
    DEFAULT_VOICE_INSTRUCT = 'female, middle-aged, moderate pitch, american accent'.freeze
    VOICE_OPTION_KEYS      = %i[voice voice_instruct instruct].freeze

    def initialize(book, stl = nil, opts = nil)
      @book = book
      @lang = @book.metadata['language'] || 'en'
      @stl = stl
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

        pages.each.with_index.peach do |page, idx|
          wavs[idx] = page.to_wav(
            dir, format('%04d', idx + 1),
            lang: @lang, stl: @stl,
            para_context: { current: para_offsets[idx], total: total_paras },
            page_context: { current: idx + 1, total: total_pages },
            book_metadata: @book.metadata,
            tts_options: speech_options
          )
        end

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
      cmd = "#{Zipper::FFMPEG} -f lavfi -i anullsrc=channel_layout=mono:sample_rate=22050 -t 1 '#{silent_wav}'"
      system(cmd)
      raise 'Failed to create silent audio file' unless File.exist?(silent_wav)
      silent_wav
    end

    def encode_audio_file(input_wav, out_audio)
      zip_opts = SymMash.new(@opts || {})
      zip_opts.speed = 1 if backend_supports?(:speech_speed) && zip_opts.speed
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
      target = out_audio.to_s
      zip_opts.skip_metamark = true
      Zipper.zip_audio(input_wav, target, opts: zip_opts)
      target
    end

    def tts_options(dir)
      options = speech_options
      options.merge!(voice_instruct_options)
      options
    end

    def speech_options
      return {} unless backend_supports?(:speech_speed) && @opts&.speed

      { speed: @opts.speed.to_f }
    end

    def backend_supports?(feature)
      method = :"supports_#{feature}?"
      TTS::BACKEND.respond_to?(method) && TTS::BACKEND.public_send(method)
    end

    def voice_instruct_options
      instruct = voice_instruct
      return {} if instruct.to_s.strip.empty?

      { instruct: instruct }
    end

    def voice_instruct
      key = VOICE_OPTION_KEYS.find { |option| @opts&.public_send(option).present? }
      normalize_voice_instruct(key ? @opts.public_send(key) : DEFAULT_VOICE_INSTRUCT)
    end

    def normalize_voice_instruct(value)
      value.to_s
        .tr('_', ' ')
        .gsub(/-pitch\b/, ' pitch')
        .gsub(/-accent\b/, ' accent')
        .split(',')
        .map(&:strip)
        .reject(&:empty?)
        .join(', ')
    end
  end
end
