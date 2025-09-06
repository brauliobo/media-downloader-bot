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

    stl&.update "Generating audio for #{paragraphs.count} paragraphs"

    Dir.mktmpdir do |dir|
      wav_files = []
      paragraphs.each_with_index do |para, idx|
        next unless para['text'] && !para['text'].empty?

        stl&.update "Synthesizing paragraph #{idx + 1}/#{paragraphs.size}"

        wav = File.join(dir, format('%04d.wav', idx + 1))
        TTS.synthesize(text: para['text'], lang: lang, out_path: wav)
        wav_files << wav
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