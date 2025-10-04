require 'pdf-reader'
require 'shellwords'
require_relative 'base'
require_relative '../text_helpers'
require_relative '../../sh'
require_relative '../../ocr'

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
          res[:lines] ? all_lines.concat(res[:lines]) : image_pages << res
        end

        sample_paras = all_lines.first(10).map { |l| { text: l[:text] || l['text'] } }.reject { |p| p[:text].to_s.strip.empty? }
        lang = Ocr.detect_language(sample_paras) || 'en'
        
        {
          metadata: { language: lang, has_ocr_pages: image_pages.any?, page_count: reader.page_count },
          content: { lines: all_lines, images: image_pages },
          opts: opts
        }
      end

      def self.extract_images(pdf_path, dir)
        Sh.run "pdftoppm -png -r 300 #{::Shellwords.escape(pdf_path)} #{File.join(dir, 'page')}"
        Dir.glob("#{File.join(dir, 'page-*.png')}").sort_by { |f| File.basename(f, '.png').split('-').last.to_i }
      end

      def self.has_text?(pdf_path, pages_to_check: 3)
        reader = PDF::Reader.new(pdf_path)
        reader.pages.first(pages_to_check).any? do |page|
          txt = (page.text rescue nil).to_s.strip
          return true if txt.length.positive?
          has_run = false
          begin
            page.runs.each { |r| has_run ||= r.text.to_s.strip.length.positive?; break if has_run }
          rescue StandardError
          end
          return true if has_run
          raw = (page.raw_content rescue nil).to_s
          raw.include?(" Tj") || raw.include?(" TJ")
        end
      rescue StandardError
        false
      end

      def self.process_page(page, pdf_path)
        page_num = page.number
        page_lines = []
        add_line = ->(text, font_size = nil, y = nil) { page_lines << { text: text, font_size: font_size, y: y, page: page_num } unless text.to_s.strip.empty? }

        # Helper to join runs left-to-right within a line
        join_runs = lambda do |runs|
          return '' if runs.nil? || runs.empty?
          parts = []
          prev = nil
          runs.sort_by { |r| r[:x] || 0 }.each do |r|
            t = r[:text]
            next if t.nil? || t.empty?
            if prev
              # add a space between segments unless hyphen-join
              if prev[:text].end_with?('-')
                parts[-1] = prev[:text].chomp('-') + t
              else
                parts << t.prepend(' ')
              end
            else
              parts << t
            end
            prev = r
          end
          parts.join
        end

        current_runs = []
        current_font_size = nil
        current_y = nil
        prev_y = nil
        page.runs.each do |run|
          text = run.text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
          next if text.empty?
          font_size = run.font_size
          y = run.y
          x = run.x rescue nil
          min_font = [current_font_size, font_size, 12].compact.min
          if prev_y && (prev_y - y).abs > (min_font * 0.3)
            joined = join_runs.call(current_runs)
            add_line.call(joined, current_font_size, current_y)
            current_runs = [{ text:, font_size:, y:, x: }]
            current_font_size = font_size
            current_y = y
          else
            current_runs << { text:, font_size:, y:, x: }
            current_font_size = [current_font_size, font_size].compact.max
            current_y ||= y
          end
          prev_y = y
        end
        joined = join_runs.call(current_runs)
        add_line.call(joined, current_font_size, current_y)

        if page_lines.empty?
          page.text.to_s.split(/\r?\n+/).each { |l| add_line.call(l) } rescue nil
        end

        if page_lines.empty?
          cmd = "pdftotext -enc UTF-8 -layout -f #{page_num} -l #{page_num} '#{pdf_path}' - 2>/dev/null"
          `#{cmd}`.to_s.split(/\r?\n+/).each { |l| add_line.call(l) } rescue nil
        end

        page_lines.any? ? { lines: page_lines } : { image: true, page: page_num, path: "#{pdf_path}#page=#{page_num}" }
      end
    end
  end
end 