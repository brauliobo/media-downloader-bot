require 'base64'
require_relative '../sh'
require 'mechanize'
require 'timeout'

class Ocr
  module Ollama

    API   = ENV['OLLAMA_HOST']
    MODEL = ENV['OLLAMA_MODEL']

    # Simple schema forcing model to return {"text": "..."}
    SCHEMA_TEMPLATE = {
      type: 'object',
      properties: {
        text: {type: 'string', description: 'Full page text with paragraphs separated by blank lines'}
      },
      required: ['text']
    }.freeze

    mattr_accessor :http
    self.http = Mechanize.new
    timeout_sec = (ENV['OLLAMA_TIMEOUT'] || 120).to_i
    self.http.open_timeout = timeout_sec
    self.http.read_timeout = timeout_sec

    def self.heading_line?(text)
      words = text.split(/\s+/)
      return false if words.empty? || words.size > 10
      upper_ratio = words.count { |w| w == w.upcase }.fdiv(words.size)
      return true if upper_ratio > 0.8
      return true if words.all? { |w| w.match?(/\A[A-Z][a-z]+\z/) }
      false
    end

    def self.merge_paragraphs(paragraphs)
      result = []
      paragraphs.each do |para|
        # Split blocks by blank lines first for better separation
        blocks = para[:text].to_s.split(/\n{2,}/).map(&:strip).reject(&:empty?)
        blocks.each do |block|
          lines = block.split(/\n+/).map(&:strip).reject(&:empty?)
          lines.each do |line|
            # Start new paragraph for heading lines
            if heading_line?(line)
              result << SymMash.new(text: line, page_numbers: para[:page_numbers].dup, merged: false, kind: 'heading')
              next
            end

            if result.any? && result.last[:text] !~ /[\.!?？¡!;:]"?$/ && result.last[:kind] != 'heading'
              result.last[:text] << ' ' << line
              result.last[:page_numbers] |= para[:page_numbers]
              result.last[:merged] = true
            else
              result << SymMash.new(text: line, page_numbers: para[:page_numbers].dup, merged: para[:merged] || false, kind: 'text')
            end
          end
        end
      end
      result
    end

    def self.transcribe pdf_path, json_path, stl: nil, timeout_sec: 120
      Dir.mktmpdir do |dir|
        # Convert PDF to PNG pages at 300 dpi for better OCR accuracy.
        Sh.run "pdftoppm -png -r 300 #{Sh.escape pdf_path} #{dir}/page"
        images = Dir.glob("#{dir}/page-*.png").sort_by { |f| File.basename(f, '.png').split('-').last.to_i }

        transcription = {metadata: {pages: []}, content: {paragraphs: []}}

        images.each_with_index do |img, idx|
          page_num = idx + 1
          stl&.update "Processing page #{page_num}/#{images.size}"
          base64   = Base64.strict_encode64 File.binread(img)

          opts = {
            model: MODEL,
            format: 'json',
            stream: false,
            options: {temperature: 0.0},
            messages: [
              {role: :system, content: SCHEMA_TEMPLATE.to_json},
              {role: :user, content: "Recognize the text in this image separating paragraphs with new lines", images: [base64]},
            ],
          }

          begin
            puts "Requesting transcription for page #{page_num}..."
            res = Timeout.timeout(timeout_sec + 5) do
              http.post "#{API}/api/chat", opts.to_json
            end
            puts "Received response for page #{page_num}."
            res = SymMash.new JSON.parse(res.body)
            page_hash = JSON.parse(res.message.content)
            text_content = page_hash['text'].to_s.strip

            if text_content.present?
              transcription[:content][:paragraphs] << {
                text: text_content,
                page_numbers: [page_num],
                merged: false,
                kind: 'text'
              }
            end

            transcription[:metadata][:pages] << { page_number: page_num }

          rescue NoMethodError => e
            puts "Error processing page #{page_num}: #{e.message}"
            transcription[:metadata][:pages] << {page_number: page_num, error: e.class.name, message: e.message, raw: res&.dig(:message, :content).to_s}
          rescue Net::ReadTimeout, Net::OpenTimeout => e
            puts "Timeout processing page #{page_num}. Skipping."
            transcription[:metadata][:pages] << {page_number: page_num, error: e.class.name, message: e.message}
          rescue Timeout::Error
            puts "Global timeout reached for page #{page_num}. Skipping."
            transcription[:metadata][:pages] << {page_number: page_num, error: 'Timeout::Error', message: "Request timed out after #{timeout_sec} seconds"}
          end
        end

        stl&.update 'OCR completed'

        # Post-process paragraphs: split by newlines and merge across pages
        transcription[:content][:paragraphs] = merge_paragraphs(transcription[:content][:paragraphs])

        File.write json_path, JSON.pretty_generate(transcription)
      end
    end

  end
end