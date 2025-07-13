# frozen_string_literal: true

require 'json'
require_relative 'ocr'
require_relative 'tts'
require_relative 'zipper'
require_relative 'exts/sym_mash'

require 'tmpdir'

class Audiobook
  # Generate audiobook from a transcription JSON or directly from a PDF file.
  # If given a PDF, it will run OCR first before synthesizing audio.
  # input_path: Path to PDF or transcription JSON
  # out_zip: Path of the resulting ZIP containing WAV files
  def self.generate(input_path, out_zip, stl: nil)
    raise "Input not found: #{input_path}" unless File.exist?(input_path)

    # Determine the transcription JSON path. If the caller provided a JSON file as
    # input, we keep it. If a PDF was provided, place the JSON alongside the
    # desired output ZIP using the same basename.
    if File.extname(input_path).downcase == '.pdf'
      json_path = File.join(File.dirname(out_zip), "#{File.basename(input_path, '.pdf')}.json")
      Ocr.transcribe(input_path, json_path, stl: stl)
    else
      json_path = input_path
    end

    process_json(json_path, out_zip)

    SymMash.new(transcription: json_path, audio: out_zip)
  end

  # Internal: synthesize audio from a transcription JSON into a ZIP.
  def self.process_json(json_path, out_zip)
    data = JSON.parse(File.read(json_path))
    lang = data.dig('metadata', 'language') || 'en'
    paragraphs = data.dig('content', 'paragraphs') || []
    Dir.mktmpdir do |dir|
      wav_files = []
      paragraphs.each_with_index do |para, idx|
        next unless para['text'] && !para['text'].empty?
        wav = File.join(dir, format('%04d.wav', idx + 1))
        TTS.synthesize(text: para['text'], lang: lang, out_path: wav)
        wav_files << wav
      end

      Zipper.zip_audio(wav_files, out_zip)
    end
  end
end 