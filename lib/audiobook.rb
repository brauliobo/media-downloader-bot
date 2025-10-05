# frozen_string_literal: true

require 'json'
require_relative 'ocr'
require_relative 'tts'
require_relative 'zipper'
require_relative 'sh'
require_relative 'exts/sym_mash'
require_relative 'translator'
require_relative 'audiobook/book'

require 'tmpdir'
require 'fileutils'
require 'set'
require 'yaml'

module Audiobook
  def self.generate(input_path, out_audio, stl: nil, opts: nil)
    raise "Input not found: #{input_path}" unless File.exist?(input_path)

    opts ||= SymMash.new
    book = Audiobook::Book.from_input(input_path, opts: opts, stl: stl)

    yaml_path = input_path.sub(/\.(pdf|epub|json)$/i, '.yml')
    yaml_path = input_path if input_path =~ /\.(yml|yaml)$/i
    yaml_path = File.join(File.dirname(out_audio), "#{File.basename(out_audio, File.extname(out_audio))}.yml") if yaml_path == input_path

    book.write(yaml_path)

    return SymMash.new(yaml: yaml_path) if opts.onlyyml

    Runner.new(book, stl, opts).process_to_audio(out_audio)
    SymMash.new(yaml: yaml_path, audio: out_audio)
  end

  class Runner
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
      Dir.mktmpdir do |dir|
        # Precompute per-page paragraph offsets to keep numbering while parallelizing pages
        para_counts  = pages.map { |p| p.items.count { |i| i.is_a?(Audiobook::Paragraph) } }
        total_paras  = para_counts.sum
        para_offsets = []
        run = 0
        para_counts.each { |c| para_offsets << run; run += c }

        wavs = Array.new(pages.size)
        total_pages = pages.size

        pages.each.with_index.peach do |page, idx|
          wavs[idx] = page.to_wav(
            dir, format('%04d', idx + 1),
            lang: @lang, stl: @stl,
            para_context: { current: para_offsets[idx], total: total_paras },
            page_context: { current: idx + 1, total: total_pages },
            book_metadata: @book.metadata
          )
        end

        # Remove nil entries (empty pages)
        wavs.compact!
        wavs = [create_silent_wav(dir)] if wavs.empty?

        combined_wav = File.join(dir, 'combined.wav')
        @stl&.update 'Concatenating audio'
        Zipper.concat_audio(wavs, combined_wav, stl: @stl)

        @stl&.update 'Encoding combined audio'
        encode_audio_file(combined_wav, out_audio)
        @stl&.update 'Audiobook ready'
      end
    end

    private

    def create_silent_audiobook(out_audio)
      @stl&.update 'No text found anywhere - creating silent audio file'

      Dir.mktmpdir do |dir|
        silent_wav = create_silent_wav(dir)
        encode_audio_file(silent_wav, out_audio) if File.exist?(silent_wav)
      end

      @stl&.update 'Silent audiobook created (no text found)'
    end

    def create_silent_wav(dir)
      silent_wav = File.join(dir, 'silent.wav')
      cmd = "ffmpeg -y -f lavfi -i anullsrc=channel_layout=mono:sample_rate=22050 -t 1 '#{silent_wav}'"
      system(cmd)
      raise 'Failed to create silent audio file' unless File.exist?(silent_wav)
      silent_wav
    end

    def encode_audio_file(input_wav, out_audio)
      zip_opts = SymMash.new(@opts || {})
      zip_opts[:format] = Zipper.choose_format(Zipper::Types.audio, zip_opts, nil)
      Zipper.zip_audio(input_wav, out_audio, opts: zip_opts)
    end
  end
end