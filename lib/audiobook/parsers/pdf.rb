require 'pdf-reader'
require_relative 'base'
require_relative '../../text_helpers'
require_relative '../../utils/sh'

module Audiobook
  module Parsers
    class Pdf < Base

      def self.extract_data(pdf_path, stl: nil, opts: nil, **_kwargs)
        all_lines = []
        image_pages = []

        reader = PDF::Reader.new(pdf_path)
        reader.pages.each_with_index do |page, idx|
          stl&.update "Analyzing document: page #{idx + 1}/#{reader.page_count}" if stl
          res = process_page(page, pdf_path)
          if res.lines
            all_lines.concat(res.lines)
          end
          # Add image if page has images (can coexist with text)
          if res.image
            image_pages << res.image
          end
        end

        SymMash.new(
          metadata: SymMash.new(has_ocr_pages: image_pages.any?, page_count: reader.page_count),
          content: SymMash.new(lines: all_lines, images: image_pages),
          opts: opts
        )
      end

      def self.extract_images(pdf_path, dir)
        Sh.run "pdftoppm -png -r 300 #{Sh.escape(pdf_path)} #{File.join(dir, 'page')}"
        Dir.glob("#{File.join(dir, 'page-*.png')}").sort_by { |f| File.basename(f, '.png').split('-').last.to_i }
      end

      def self.has_text?(pdf_path, pages_to_check: 3)
        reader = PDF::Reader.new(pdf_path)
        reader.pages.first(pages_to_check).any? do |page|
          txt = page.text.to_s.strip
          return true if txt.length.positive?
          has_run = false
          begin
            page.runs.each { |r| has_run ||= r.text.to_s.strip.length.positive?; break if has_run }
          rescue StandardError
          end
          return true if has_run
          raw = page.raw_content.to_s
          raw.include?(" Tj") || raw.include?(" TJ")
        end
      rescue StandardError
        false
      end

      def self.process_page(page, pdf_path)
        page_num = page.number
        page_lines = []
        add_line = ->(text, font_size = nil, y = nil, x = nil) { 
          page_lines << SymMash.new(text: text, font_size: font_size, y: y, x: x, page: page_num) unless text.to_s.strip.empty? 
        }

        # Helper to join runs left-to-right within a line and get min x position
        join_runs = lambda do |runs|
          return ['', nil] if runs.nil? || runs.empty?
          parts = []
          prev = nil
          min_x = nil
          normalized_runs = runs.map { |r| r.is_a?(Hash) ? SymMash.new(r) : r }
          normalized_runs.sort_by { |r| r.x || 0 }.each do |r|
            t = r.text
            next if t.nil? || t.empty?
            min_x = r.x if r.x && (min_x.nil? || r.x < min_x)
            if prev
              # add a space between segments unless hyphen-join
              if prev.text.end_with?('-')
                parts[-1] = prev.text.chomp('-') + t
              else
                parts << t.prepend(' ')
              end
            else
              parts << t
            end
            prev = r
          end
          [parts.join, min_x]
        end

        current_runs = []
        current_font_size = nil
        current_y = nil
        current_x = nil
        prev_y = nil
        page.runs.each do |run|
          text = run.text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
          next if text.empty?
          font_size = run.font_size
          y = run.y
          x = run.x rescue nil
          min_font = [current_font_size, font_size, 12].compact.min
          if prev_y && (prev_y - y).abs > (min_font * 0.3)
            joined, min_x = join_runs.call(current_runs)
            add_line.call(joined, current_font_size, current_y, min_x)
            current_runs = [SymMash.new(text: text, font_size: font_size, y: y, x: x)]
            current_font_size = font_size
            current_y = y
            current_x = x
          else
            current_runs << SymMash.new(text: text, font_size: font_size, y: y, x: x)
            current_font_size = [current_font_size, font_size].compact.max
            current_y ||= y
            current_x = x if current_x.nil? || (x && x < current_x)
          end
          prev_y = y
        end
        joined, min_x = join_runs.call(current_runs)
        add_line.call(joined, current_font_size, current_y, min_x || current_x)

        if page_lines.empty?
          page.text.to_s.split(/\r?\n+/).each { |l| add_line.call(l) }
        end

        if page_lines.empty?
          cmd = "pdftotext -enc UTF-8 -layout -f #{page_num} -l #{page_num} '#{pdf_path}' - 2>/dev/null"
          `#{cmd}`.to_s.split(/\r?\n+/).each { |l| add_line.call(l) }
        end

        # Calculate spacing between lines and add x_position
        page_lines.each_with_index do |line, idx|
          next if line.y.nil?
          
          # Calculate top spacing (distance from previous line's bottom)
          if idx > 0 && page_lines[idx - 1].y
            prev_bottom = page_lines[idx - 1].y
            current_top = line.y
            line.top_spacing = prev_bottom - current_top
          end
          
          # Calculate bottom spacing (distance to next line's top)
          if idx < page_lines.size - 1 && page_lines[idx + 1].y
            current_bottom = line.y
            next_top = page_lines[idx + 1].y
            line.bottom_spacing = current_bottom - next_top
          end
          
          # Ensure x_position is set (default to 0 if not available)
          line.x ||= 0
        end

        # Detect if page has images using pdfimages tool (more reliable)
        has_images = begin
          # Check if pdfimages can list images for this page
          cmd = "pdfimages -f #{page_num} -l #{page_num} -list #{Sh.escape(pdf_path)} 2>/dev/null"
          output = `#{cmd}`
          # pdfimages outputs header lines, then image lines starting with spaces+digits+"image"
          # Skip header lines (starting with "page" or dashes) and check for image lines
          output.lines.any? { |line| line.match?(/^\s+\d+\s+\d+\s+image/i) }
        rescue StandardError
          false
        end

        result = SymMash.new
        result.lines = page_lines if page_lines.any?
        if has_images || page_lines.empty?
          result.image = SymMash.new(image: true, page: page_num, path: "#{pdf_path}#page=#{page_num}")
        end

        result
      end
    end
  end
end 