# frozen_string_literal: true

require 'json'
require_relative 'ocr'
require_relative 'tts'
require_relative 'zipper'
require_relative 'sh'
require_relative 'exts/sym_mash'

require 'tmpdir'
require 'fileutils'

class Audiobook
  # Generate audiobook from a transcription JSON or a PDF.
  # If PDF is provided OCR runs first.
  # input_path: PDF or transcription JSON path
  # out_audio: Path for final encoded audio (e.g., .opus)
  def self.generate(input_path, out_audio, stl: nil, opts: nil)
    raise "Input not found: #{input_path}" unless File.exist?(input_path)

    # Determine the transcription JSON path. If the caller provided a JSON file as
    # input, we keep it. If a PDF was provided, place the JSON alongside the
    # desired output ZIP using the same basename.
    if File.extname(input_path).downcase == '.pdf'
      json_base = File.basename(out_audio, File.extname(out_audio))
      json_path = File.join(File.dirname(out_audio), "#{json_base}.json")
      Ocr.transcribe(input_path, json_path, stl: stl, opts: opts)
    else
      json_path = input_path
    end

    process_json(json_path, out_audio, stl: stl, opts: opts)

    SymMash.new(transcription: json_path, audio: out_audio)
  end

  # Internal: synthesize audio from a transcription JSON into a ZIP.
  def self.process_json(json_path, out_audio, stl: nil, opts: nil)
    data = JSON.parse(File.read(json_path))
    lang = data.dig('metadata', 'language') || 'en'
    paragraphs = data.dig('content', 'paragraphs') || []

    # Debug: log the JSON structure to understand what we're getting
    puts "[DEBUG] JSON data keys: #{data.keys}"
    puts "[DEBUG] Content keys: #{data['content']&.keys}"
    puts "[DEBUG] Paragraphs found: #{paragraphs.count}"
    paragraphs.each_with_index do |para, idx|
      puts "[DEBUG] Paragraph #{idx}: #{para['text']&.slice(0, 100)}..."
    end

    # Fallback: if no paragraphs found, try to extract text from other locations
    if paragraphs.empty?
      stl&.update 'No paragraphs found, checking for alternative text sources'
      
      # Try to find text in different JSON structures
      alternative_text = nil
      
      # Check if there's raw text in the data
      if data['text']
        alternative_text = data['text']
      elsif data['content'] && data['content']['text']
        alternative_text = data['content']['text']
      elsif data['content'] && data['content']['pages']
        # Extract text from pages structure
        pages_text = data['content']['pages'].map { |page| page['text'] }.compact.join(' ')
        alternative_text = pages_text unless pages_text.empty?
      elsif data['metadata'] && data['metadata']['pages']
        # Extract text from metadata.pages (headers/footers)
        pages_text = []
        data['metadata']['pages'].each do |page|
          pages_text << page['header'] if page['header'] && !page['header'].strip.empty?
          pages_text << page['footer'] if page['footer'] && !page['footer'].strip.empty?
        end
        alternative_text = pages_text.uniq.join(' ') unless pages_text.empty?
      end
      
      if alternative_text && !alternative_text.strip.empty?
        stl&.update 'Found alternative text, creating single paragraph'
        paragraphs = [{ 'text' => alternative_text.strip }]
        puts "[DEBUG] Created paragraph from alternative text: #{alternative_text.slice(0, 100)}..."
      end
    end

    stl&.update "Generating audio for #{paragraphs.count} paragraphs"

    # Handle still empty paragraphs case
    if paragraphs.empty?
      stl&.update 'No text found anywhere - creating silent audio file'
      
      # Create a minimal silent audio file
      Dir.mktmpdir do |dir|
        silent_wav = File.join(dir, 'silent.wav')
        # Create 1 second of silence using ffmpeg
        cmd = "ffmpeg -y -f lavfi -i anullsrc=channel_layout=mono:sample_rate=22050 -t 1 '#{silent_wav}'"
        system(cmd)
        
        if File.exist?(silent_wav)
          zip_opts = SymMash.new(opts || {})
          zip_opts[:format] = Zipper.choose_format(Zipper::Types.audio, zip_opts, nil)
          Zipper.zip_audio(silent_wav, out_audio, opts: zip_opts)
        else
          raise "Failed to create silent audio file"
        end
      end
      
      stl&.update 'Silent audiobook created (no text found)'
      return
    end

    Dir.mktmpdir do |dir|
      wav_files = []
      paragraphs.each_with_index do |para, idx|
        next unless para['text'] && !para['text'].empty?

        stl&.update "Synthesizing paragraph #{idx + 1}/#{paragraphs.size}"

        wav = File.join(dir, format('%04d.wav', idx + 1))
        TTS.synthesize(text: para['text'], lang: lang, out_path: wav)
        wav_files << wav
      end

      # Handle case where all paragraphs were filtered out
      if wav_files.empty?
        stl&.update 'No valid text found - creating empty audio file'
        
        # Create a minimal silent audio file
        silent_wav = File.join(dir, 'silent.wav')
        cmd = "ffmpeg -y -f lavfi -i anullsrc=channel_layout=mono:sample_rate=22050 -t 1 '#{silent_wav}'"
        system(cmd)
        wav_files << silent_wav if File.exist?(silent_wav)
      end

      # Concatenate all WAVs into a single file.
      stl&.update 'Concatenating audio'

      combined_wav = File.join(dir, 'combined.wav')
      Zipper.concat_audio(wav_files, combined_wav, stl: stl)

      # Encode to desired audio format (default opus) using Zipper.
      stl&.update 'Encoding combined audio'

      zip_opts = SymMash.new(opts || {})
      zip_opts[:format] = Zipper.choose_format(Zipper::Types.audio, zip_opts, nil)
      Zipper.zip_audio(combined_wav, out_audio, opts: zip_opts)

      stl&.update 'Audiobook ready'
    end
  end
end