class Ocr
  module Pdf
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
      image_pages = []

      reader.pages.each_with_index do |page, idx|
        page_num = idx + 1
        stl&.update "Extract content from page #{page_num}/#{reader.page_count}"

        # Extract text runs with font and position info
        current_text = ''
        current_font_size = nil
        current_y = nil
        prev_y = nil
        page_has_text = false
        
        page.runs.each do |run|
          text = run.text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
          font_size = run.font_size
          y_pos = run.y
          
          # New line detected by Y position change
          min_font = [current_font_size, font_size, 12].compact.min
          if prev_y && (prev_y - y_pos).abs > (min_font * 0.3)
            unless current_text.strip.empty?
              all_lines << { text: current_text, font_size: current_font_size, y: current_y, page: page_num }
              page_has_text = true
            end
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
        
        unless current_text.strip.empty?
          all_lines << { text: current_text, font_size: current_font_size, y: current_y, page: page_num }
          page_has_text = true
        end
        
        # If page has no text, mark it for image-based OCR later by Image class
        unless page_has_text
          image_pages << { page: page_num, path: "#{pdf_path}#page=#{page_num}" }
        end
      end

      # Store raw lines and image pages for processing by Book class
      # (Header/footer detection and filtering will be handled by Book)
      transcription = {
        metadata: { language: 'pt' },
        content: { 
          lines: all_lines,
          images: image_pages
        },
        opts: opts
      }

      stl&.update 'Saving transcription'
      File.write json_path, JSON.pretty_generate(transcription)
      stl&.update 'Done'
    end

    # (Image rasterization and OCR are handled by Audiobook::Image)
  end
end 