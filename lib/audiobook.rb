# frozen_string_literal: true

require 'json'
require_relative 'ocr'
require_relative 'tts'
require_relative 'zipper'
require_relative 'sh'
require_relative 'exts/sym_mash'
require_relative 'translator'

require 'tmpdir'
require 'fileutils'
require 'set'

class Audiobook
  # Generate audiobook from a transcription JSON or a document (PDF/EPUB).
  # If document is provided OCR/Parsing runs first.
  # input_path: PDF/EPUB or transcription JSON path
  # out_audio: Path for final encoded audio (e.g., .opus)
  def self.generate(input_path, out_audio, stl: nil, opts: nil)
    raise "Input not found: #{input_path}" unless File.exist?(input_path)

    json_path = determine_json_path(input_path, out_audio, stl: stl, opts: opts)
    process_json(json_path, out_audio, stl: stl, opts: opts)

    SymMash.new(transcription: json_path, audio: out_audio)
  end

  # Internal: synthesize audio from a transcription JSON into a ZIP.
  def self.process_json(json_path, out_audio, stl: nil, opts: nil)
    new(json_path, stl, opts).process_to_audio(out_audio)
  end

  def initialize(json_path, stl = nil, opts = nil)
    @data = JSON.parse(File.read(json_path))
    @lang = @data.dig('metadata', 'language') || 'en'
    @stl = stl
    @opts = opts
  end

  def process_to_audio(out_audio)
    paragraphs = extract_paragraphs
    return create_silent_audiobook(out_audio) if paragraphs.empty?

    paragraphs = translate_paragraphs(paragraphs) if translation_needed?

    @stl&.update "Generating audio for #{paragraphs.count} paragraphs"
    create_audiobook_from_paragraphs(paragraphs, out_audio)
  end

  private

  # Determine the transcription JSON path from input (.pdf/.epub => produce .json)
  def self.determine_json_path(input_path, out_audio, stl: nil, opts: nil)
    ext = File.extname(input_path).downcase
    return input_path unless ['.pdf', '.epub'].include?(ext)

    json_base = File.basename(out_audio, File.extname(out_audio))
    json_path = File.join(File.dirname(out_audio), "#{json_base}.json")
    Ocr.transcribe(input_path, json_path, stl: stl, opts: opts)
    json_path
  end

  # Extract paragraphs from JSON data with fallback strategies
  def extract_paragraphs
    paragraphs = @data.dig('content', 'paragraphs') || []
    debug_json_structure(paragraphs)

    return paragraphs unless paragraphs.empty?

    @stl&.update 'No paragraphs found, checking for alternative text sources'
    alternative_text = find_alternative_text

    return [] unless alternative_text&.strip&.length&.positive?

    @stl&.update 'Found alternative text, creating single paragraph'
    puts "[DEBUG] Created paragraph from alternative text: #{alternative_text.slice(0, 100)}..."
    [{ 'text' => alternative_text.strip }]
  end

  # Debug: log the JSON structure
  def debug_json_structure(paragraphs)
    puts "[DEBUG] JSON data keys: #{@data.keys}"
    puts "[DEBUG] Content keys: #{@data['content']&.keys}"
    puts "[DEBUG] Paragraphs found: #{paragraphs.count}"
    paragraphs.each_with_index { |para, idx| puts "[DEBUG] Paragraph #{idx}: #{para['text']&.slice(0, 100)}..." }
  end

  # Find alternative text from various JSON structures
  def find_alternative_text
    return @data['text'] if @data['text']
    return @data['content']['text'] if @data.dig('content', 'text')
    return extract_pages_text if @data.dig('content', 'pages')
    return extract_headers_footers if @data.dig('metadata', 'pages')
  end

  # Extract text from content pages
  def extract_pages_text
    pages_text = @data['content']['pages'].map { |page| page['text'] }.compact.join(' ')
    pages_text.empty? ? nil : pages_text
  end

  # Extract headers/footers, excluding those that appeared as headers/footers in previous pages
  def extract_headers_footers
    pages_text = []
    prev_headers = Set.new
    prev_footers = Set.new

    @data['metadata']['pages'].each do |page|
      pages_text << process_header(page, prev_headers)
      pages_text << process_footer(page, prev_footers)
    end

    pages_text.compact.uniq.join(' ').then { |text| text.empty? ? nil : text }
  end

  # Process header text - include unless it appeared as header in previous pages
  def process_header(page, prev_headers)
    return unless page['header']&.strip&.length&.positive?

    header_text = page['header'].strip
    result = header_text unless prev_headers.include?(header_text)
    prev_headers << header_text
    result
  end

  # Process footer text - include unless it appeared as footer in previous pages
  def process_footer(page, prev_footers)
    return unless page['footer']&.strip&.length&.positive?

    footer_text = page['footer'].strip
    result = footer_text unless prev_footers.include?(footer_text)
    prev_footers << footer_text
    result
  end

  # Create silent audiobook when no text is found
  def create_silent_audiobook(out_audio)
    @stl&.update 'No text found anywhere - creating silent audio file'

    Dir.mktmpdir do |dir|
      silent_wav = create_silent_wav(dir)
      encode_audio_file(silent_wav, out_audio) if File.exist?(silent_wav)
    end

    @stl&.update 'Silent audiobook created (no text found)'
  end

  # Create audiobook from paragraphs
  def create_audiobook_from_paragraphs(paragraphs, out_audio)
    Dir.mktmpdir do |dir|
      wav_files = synthesize_paragraphs(paragraphs, dir)
      wav_files = [create_silent_wav(dir)] if wav_files.empty?

      combined_wav = File.join(dir, 'combined.wav')
      @stl&.update 'Concatenating audio'
      Zipper.concat_audio(wav_files, combined_wav, stl: @stl)

      @stl&.update 'Encoding combined audio'
      encode_audio_file(combined_wav, out_audio)
      @stl&.update 'Audiobook ready'
    end
  end

  # Synthesize audio for each paragraph
  def synthesize_paragraphs(paragraphs, dir)
    wav_files = []
    paragraphs.each_with_index do |para, idx|
      next unless para['text']&.length&.positive?

      @stl&.update "Synthesizing paragraph #{idx + 1}/#{paragraphs.size}"
      wav = File.join(dir, format('%04d.wav', idx + 1))
      TTS.synthesize(text: para['text'], lang: @lang, out_path: wav)
      wav_files << wav
    end
    wav_files
  end

  # Create a silent WAV file
  def create_silent_wav(dir)
    silent_wav = File.join(dir, 'silent.wav')
    cmd = "ffmpeg -y -f lavfi -i anullsrc=channel_layout=mono:sample_rate=22050 -t 1 '#{silent_wav}'"
    system(cmd)
    raise 'Failed to create silent audio file' unless File.exist?(silent_wav)
    silent_wav
  end

  # Encode audio file with proper format
  def encode_audio_file(input_wav, out_audio)
    zip_opts = SymMash.new(@opts || {})
    zip_opts[:format] = Zipper.choose_format(Zipper::Types.audio, zip_opts, nil)
    Zipper.zip_audio(input_wav, out_audio, opts: zip_opts)
  end

  # Check if translation is needed
  def translation_needed?
    return false unless @opts&.lang
    return false unless @lang
    @opts.lang.to_s != @lang.to_s
  end

  # Translate paragraphs if target language differs from source
  def translate_paragraphs(paragraphs)
    return paragraphs unless translation_needed?

    @stl&.update 'Translating paragraphs'
    
    # Translate each paragraph individually
    translated_paragraphs = paragraphs.map.with_index do |para, idx|
      if para['text']&.length&.positive?
        @stl&.update "Translating paragraph #{idx + 1}/#{paragraphs.size}"
        translated_text = Translator.translate(para['text'], from: @lang, to: @opts.lang)
        para.merge('text' => translated_text)
      else
        para
      end
    end

    # Update the language for TTS
    @lang = @opts.lang.to_s
    
    @stl&.update "Translated to #{@lang}"
    translated_paragraphs
  end
end