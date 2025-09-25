require 'base64'
require_relative '../sh'
require 'mechanize'
require 'timeout'

class Ocr
  module Ollama

    API   = ENV['OLLAMA_HOST']
    MODEL = ENV['OLLAMA_OCR_MODEL']

    PROMPT = "Recognize the text in this image. Skip the book page headers or footers. Output only the plain text exactly as seen, with each heading or paragraph separated by a blank line. Do NOT return JSON, markup, or commentary—just the text.".freeze
    PROMPT_INCLUDE_ALL = "Recognize the text in this image. Include everything present, including any headers, footers, page numbers, and marginalia. Output only the plain text exactly as seen, with each heading or paragraph separated by a blank line. Do NOT return JSON, markup, or commentary—just the text.".freeze
    USE_AI_MERGE = ENV.fetch('AI_MERGE', '0') == '1'

    AI_MERGE_PROMPT = "You will be given two consecutive blocks of text extracted from a scanned book page. If they represent a single logical paragraph that was split across lines/pages, respond with ONLY the word YES. Otherwise respond with ONLY the word NO.".freeze

    # Language detection
    LANG_PROMPT_TEMPLATE = "What is the ISO 639-1 two-letter language code of the following text? Respond with ONLY the code (e.g., `en`, `es`).\n\n".freeze
    USE_AI_LANG   = ENV.fetch('AI_LANG', '1') == '1'
    LANG_SCHEMA = {type:'object',properties:{lang:{type:'string'}},required:['lang']}.to_json.freeze

    mattr_accessor :http
    self.http = Manager.http

    # use helpers from Ocr module

    # Ask the LLM whether consecutive paragraphs should be merged.
    def self.ai_merge_paragraphs(paragraphs, timeout_sec: 30)
      return paragraphs unless USE_AI_MERGE
      out = []
      paragraphs.each do |para|
        if out.any?
          prev = out.last
          # Only consider merging non-heading paragraphs
          if prev[:kind] == 'text' && para[:kind] == 'text'
            q = {
              model: MODEL,
              stream: false,
              options: {temperature: 0.0},
              messages: [
                {role: :user, content: AI_MERGE_PROMPT},
                {role: :assistant, content: ''},
                {role: :user, content: "FIRST:\n#{prev[:text]}\nSECOND:\n#{para[:text]}"}
              ]
            }
            begin
              res = Timeout.timeout(timeout_sec) do
                http.post "#{API}/api/chat", q.to_json
              end
              ans = SymMash.new(JSON.parse(res.body)).dig(:message, :content).to_s.strip.upcase
              if ans == 'YES'
                prev[:text] << ' ' << para[:text]
                prev[:page_numbers] |= para[:page_numbers]
                prev[:merged] = true
                next
              end
            rescue StandardError
              # On any failure, do not merge
            end
          end
        end
        out << para
      end
      out
    end

    def self.detect_language(paragraphs, timeout_sec: 15)
      return nil unless USE_AI_LANG && paragraphs.any?
      sample_text = paragraphs.first(5).map { |p| p[:text] }.join("\n")[0, 1000]
      prompt = LANG_PROMPT_TEMPLATE + """\n#{sample_text}\n"""
      q = {
        model: MODEL,
        format: JSON.parse(LANG_SCHEMA),
        stream: false,
        options: {temperature: 0.0},
        messages: [
          {role: :user, content: prompt}
        ]
      }
      begin
        res = Timeout.timeout(timeout_sec) { http.post "#{API}/api/chat", q.to_json }
        ans = SymMash.new(JSON.parse(res.body)).dig(:message, :content)
        lang_obj = JSON.parse(ans) rescue nil
        code = lang_obj && lang_obj['lang'] ? lang_obj['lang'].downcase.strip : nil
        return code.match?(/^[a-z]{2}$/) ? code : nil
      rescue StandardError
        nil
      end
    end

    def self.transcribe pdf_path, json_path, stl: nil, timeout_sec: 120, opts: nil
      Dir.mktmpdir do |dir|
        # Convert PDF to PNG pages at 300 dpi for better OCR accuracy.
        Sh.run "pdftoppm -png -r 300 #{Sh.escape pdf_path} #{dir}/page"
        images = Dir.glob("#{dir}/page-*.png").sort_by { |f| File.basename(f, '.png').split('-').last.to_i }

        transcription = {metadata: {pages: []}, content: {paragraphs: []}}

        images.each_with_index do |img, idx|
          page_num = idx + 1
          stl&.update "Processing page #{page_num}/#{images.size}"
          base64   = Base64.strict_encode64 File.binread(img)

          include_all = !!(opts && (opts[:includeall] || opts['includeall']))
          q = {
            model: MODEL,
            stream: false,
            options: {temperature: 0.0},
            messages: [
              {role: :user, content: (include_all ? PROMPT_INCLUDE_ALL : PROMPT), images: [base64]},
            ],
          }

          begin
            res = Timeout.timeout(timeout_sec + 5) do
              http.post "#{API}/api/chat", q.to_json
            end
            res = SymMash.new JSON.parse(res.body)
            text_content = res.dig(:message, :content).to_s.strip

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

        stl&.update 'Merging paragraphs'
        # Post-process paragraphs: split by newlines and merge across pages
        blocks = Ocr.util.merge_paragraphs(transcription[:content][:paragraphs])

        if USE_AI_MERGE
          stl&.update 'AI merging paragraphs'
          blocks = ai_merge_paragraphs(blocks)
        end
        transcription[:content][:paragraphs] = blocks

        stl&.update 'Detecting language'
        # Detect language and store in metadata
        transcription[:metadata][:language] = detect_language(blocks)

        stl&.update 'Saving transcription'
        File.write json_path, JSON.pretty_generate(transcription)
        stl&.update 'Done'
      end
    end

  end
end