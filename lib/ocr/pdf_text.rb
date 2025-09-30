class Ocr
  module PDFText
    require 'pdf-reader'

    # Check if the PDF contains an embedded text layer by inspecting the first
    # few pages (default: 3). Returns true when any inspected page yields some
    # extractable text.
    def self.has_text?(pdf_path, pages_to_check: 3)
      reader = PDF::Reader.new(pdf_path)
      reader.pages.first(pages_to_check).any? { |page| page.text.to_s.strip.length.positive? }
    rescue StandardError
      false
    end

    # Extract text from a digital (non-scanned) PDF and save it in the same JSON
    # structure produced by the Ollama backend so downstream consumers remain
    # unaffected.
    def self.transcribe(pdf_path, json_path, stl: nil, opts: nil, **_kwargs)
      reader = PDF::Reader.new(pdf_path)
      all_lines = []

      reader.pages.each_with_index do |page, idx|
        page_num = idx + 1
        stl&.update "Extracting text from page #{page_num}/#{reader.page_count}"

        # Extract text runs with font and position info
        current_text = ''
        current_font_size = nil
        current_y = nil
        prev_y = nil
        
        page.runs.each do |run|
          text = run.text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
          font_size = run.font_size
          y_pos = run.y
          
          # New line detected by Y position change
          min_font = [current_font_size, font_size, 12].compact.min
          if prev_y && (prev_y - y_pos).abs > (min_font * 0.3)
            all_lines << { text: current_text, font_size: current_font_size, y: current_y, page: page_num } unless current_text.strip.empty?
            current_text = text
            current_font_size = font_size
            current_y = y_pos
          else
            current_text << text
            current_font_size = [current_font_size, font_size].compact.max
            current_y ||= y_pos
          end
          prev_y = y_pos
        end
        all_lines << { text: current_text, font_size: current_font_size, y: current_y, page: page_num } unless current_text.strip.empty?
      end

      stl&.update 'Detecting headers/footers'

      # Detect headers/footers by finding lines that appear on >30% of pages
      norm = ->(s) { s.downcase.gsub(/\d+/, '<d>').gsub(/\s+/, ' ').strip }
      pages_hash = all_lines.group_by { |l| l[:page] }
      hdrf_counts = Hash.new(0)
      
      pages_hash.each do |_, lines|
        first_text = lines.first&.dig(:text)
        last_text = lines.last&.dig(:text)
        [first_text, last_text].compact.map(&norm).each { |l| hdrf_counts[l] += 1 }
      end
      
      threshold = (pages_hash.size * 0.3).ceil
      hdrf_set = hdrf_counts.select { |_, c| c >= threshold }.keys
      include_all = !!(opts && (opts[:includeall] || opts['includeall']))
      
      # Filter out headers/footers unless includeall
      clean_lines = include_all ? all_lines : all_lines.reject { |l| hdrf_set.include?(norm.call(l[:text])) }
      
      # Store lines with metadata for processing by Book class
      transcription = {
        metadata: { language: 'pt' },
        content: { lines: clean_lines }
      }

      stl&.update 'Saving transcription'
      File.write json_path, JSON.pretty_generate(transcription)
      stl&.update 'Done'
    end
  end
end 