module Audiobook
  module Parsers
    class Pdf
      # What pdfinfo says of the document: its fields and its number of pages.
      module Info
        def extract_pdfinfo(pdf_path)
          output, stderr, status = Sh.run ['pdfinfo', pdf_path]
          Sh.assert_success!('PDF page count failed', stderr, status: status)
          count = output[/^Pages:\s+(\d+)$/i, 1]&.to_i
          raise 'PDF page count missing' unless count&.positive?

          SymMash.new(pages: count, title: pdfinfo_field(output, 'Title'), author: pdfinfo_field(output, 'Author'))
        end

        def pdfinfo_field(output, label)
          value = output[/^#{Regexp.escape(label)}:\s+(.+)$/i, 1]&.strip
          value if value.present? && value != '-'
        end

        def extract_page_count(pdf_path)
          extract_pdfinfo(pdf_path).pages
        end

        def consecutive_ranges(page_numbers)
          page_numbers.slice_when { |left, right| right != left + 1 }.map { |range| [range.first, range.last] }
        end
      end
    end
  end
end
