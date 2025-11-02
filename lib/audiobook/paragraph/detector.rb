require_relative '../line'
require_relative '../sentence'
require_relative '../paragraph'
require_relative 'factory'
require_relative '../../text_helpers'

module Audiobook
  class Paragraph
    class Detector
      def self.discover_from_lines(lines)
        new(lines).detect
      end

      def initialize(lines)
        @lines = lines
        @baseline_spacing = calculate_baseline_spacing(lines)
        @spacing_threshold = @baseline_spacing * 1.5
        @indent_threshold = calculate_indent_threshold(lines)
      end

      def detect
        return [] if @lines.empty?

        items_with_pages = []
        buf = []
        prev_line = nil
        start_page = nil

        @lines.each do |line|
          start_page ||= line.page_number

          if buf.any? && prev_line
            # Dehyphenate across lines
            if prev_line.ends_with_hyphen? && line.starts_with_lowercase?
              buf[-1] = Line.new(
                buf.last.text.chomp('-') + line.text,
                font_size: prev_line.font_size,
                page_number: prev_line.page_number,
                x_position: prev_line.x_position,
                top_spacing: prev_line.top_spacing,
                bottom_spacing: prev_line.bottom_spacing
              )
              prev_line = buf.last
              next
            end

            should_break = BreakDetector.should_break?(
              prev_line, line, buf,
              spacing_threshold: @spacing_threshold,
              indent_threshold: @indent_threshold
            )
          else
            should_break = false
          end

          if should_break
            items = Factory.create_items_from_lines(buf, start_page)
            items_with_pages.concat(items)
            buf = [line]
            start_page = line.page_number
          else
            buf << line
          end
          prev_line = line
        end

        if buf.any?
          items = Factory.create_items_from_lines(buf, start_page)
          items_with_pages.concat(items)
        end

        items_with_pages.reject { |data| data[:item].is_a?(Paragraph) && data[:item].empty? }
      end

      private

      def calculate_baseline_spacing(lines)
        spacings = lines.compact.map(&:top_spacing).compact.select { |s| s > 0 }
        return 0 if spacings.empty?

        sorted = spacings.sort
        mid = sorted.size / 2
        sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
      end

      def calculate_indent_threshold(lines)
        x_positions = lines.compact.map(&:x_position).compact.select { |x| x && x > 0 }
        return 0 if x_positions.empty?

        rounded = x_positions.map { |x| (x / 10).round * 10 }
        counts = rounded.each_with_object(Hash.new(0)) { |x, h| h[x] += 1 }
        most_common = counts.max_by { |_, c| c }&.first || 0

        most_common > 0 ? most_common * 0.5 : 20
      end
    end

    class BreakDetector
      def self.should_break?(prev_line, line, buf, spacing_threshold:, indent_threshold:)
        # Dehyphenate check is handled before calling this
        
        font_changed = line.font_changed?(prev_line)
        page_changed = line.page_number != prev_line.page_number
        is_only_numbers = line.text.match?(/^\d+$/)

        spacing_break = detect_spacing_break(prev_line, line, spacing_threshold)
        indent_break = detect_indent_break(prev_line, line, indent_threshold)

        buffer_text = buf.map(&:text).join(' ').strip
        sentence_finished = Sentence.ends_with_punctuation?(buffer_text)

        should_break = is_only_numbers || font_changed || (sentence_finished && line.starts_with_capital?)
        should_break = true if (spacing_break || indent_break) && sentence_finished

        if should_break
          should_break = false if TextHelpers.starts_with_ref_markers?(line.text)
        end

        if page_changed && !sentence_finished && !font_changed && !is_only_numbers && !spacing_break && !indent_break
          should_break = false
        end

        should_break
      end

      def self.detect_spacing_break(prev_line, line, threshold)
        if prev_line.bottom_spacing && line.top_spacing
          spacing = [prev_line.bottom_spacing, line.top_spacing].max
          spacing > threshold && spacing > 0
        elsif prev_line.bottom_spacing
          prev_line.bottom_spacing > threshold
        elsif line.top_spacing
          line.top_spacing > threshold
        else
          false
        end
      end

      def self.detect_indent_break(prev_line, line, threshold)
        return false unless prev_line.x_position && line.x_position && threshold > 0

        x_diff = (line.x_position - prev_line.x_position).abs
        x_diff >= threshold && line.x_position > prev_line.x_position
      end
    end
  end
end
