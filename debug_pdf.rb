#!/usr/bin/env ruby

# Debug script to test PDF processing pipeline
require_relative 'lib/manager'
require_relative 'lib/audiobook'
require_relative 'lib/ocr'
require 'tmpdir'
require 'json'

def debug_pdf_processing(pdf_path)
  puts "=== PDF Processing Debug ==="
  puts "PDF: #{pdf_path}"
  puts "Exists: #{File.exist?(pdf_path)}"
  puts "Size: #{File.size(pdf_path)} bytes" if File.exist?(pdf_path)
  
  return unless File.exist?(pdf_path)
  
  Dir.mktmpdir do |tmpdir|
    puts "\nTesting OCR backends..."
    
    # Test if PDF has embedded text
    has_text = Ocr::PDFText.has_text?(pdf_path)
    puts "Has embedded text: #{has_text}"
    
    # Test JSON generation
    json_path = File.join(tmpdir, 'transcription.json')
    puts "\nGenerating transcription..."
    
    begin
      Ocr.transcribe(pdf_path)
      puts "Transcription saved: #{json_path}"
      puts "JSON size: #{File.size(json_path)} bytes"
      
      # Parse and analyze JSON
      data = JSON.parse(File.read(json_path))
      puts "\nJSON Analysis:"
      puts "Keys: #{data.keys}"
      puts "Content keys: #{data['content']&.keys}"
      paragraphs = data.dig('content', 'paragraphs') || []
      puts "Paragraphs found: #{paragraphs.count}"
      
      if paragraphs.empty?
        puts "No paragraphs found - checking alternatives..."
        puts "Text key: #{data['text'] ? 'present' : 'missing'}"
        puts "Content text: #{data.dig('content', 'text') ? 'present' : 'missing'}"
        puts "Pages: #{data.dig('content', 'pages') ? 'present' : 'missing'}"
      else
        paragraphs.first(3).each_with_index do |para, i|
          puts "Paragraph #{i}: #{para['text']&.slice(0, 100)}..."
        end
      end
      
      # Test TTS server connectivity
      puts "\nTesting TTS server..."
      begin
        require 'net/http'
        uri = URI("http://127.0.0.1:#{ENV['PORT'] || 10230}/synthesize")
        response = Net::HTTP.get_response(uri.host, '/', uri.port)
        puts "TTS server status: #{response.code}"
      rescue => e
        puts "TTS server error: #{e.message}"
        puts "Make sure Coqui TTS server is running on port #{ENV['PORT'] || 10230}"
      end
      
      # Test audiobook generation
      audio_path = File.join(tmpdir, 'test.opus')
      puts "\nGenerating audiobook..."
      
      begin
        result = Audiobook.generate(pdf_path, audio_path)
        puts "Audiobook generated: #{audio_path}"
        puts "Audio size: #{File.size(audio_path)} bytes" if File.exist?(audio_path)
        puts "Transcription: #{result.transcription}"
        puts "Audio: #{result.audio}"
      rescue => e
        puts "Audiobook generation failed: #{e.message}"
        puts e.backtrace.first(5)
      end
      
    rescue => e
      puts "OCR failed: #{e.message}"
      puts e.backtrace.first(5)
    end
  end
end

if ARGV.empty?
  puts "Usage: ruby debug_pdf.rb <path_to_pdf>"
  exit 1
end

debug_pdf_processing(ARGV[0])
