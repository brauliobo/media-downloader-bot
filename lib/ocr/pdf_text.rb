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
    def self.transcribe(pdf_path, json_path, stl: nil, **_kwargs)
      reader = PDF::Reader.new(pdf_path)

      pages_lines = []

      reader.pages.each_with_index do |page, idx|
        page_num = idx + 1
        stl&.update "Extracting text from page #{page_num}/#{reader.page_count}"

        # Split page text into lines, keep blank lines for paragraph boundaries
        lines = page.text.to_s.split(/\r?\n/).map { |l| l.rstrip }
        pages_lines << { num: page_num, lines: lines }
      end

      stl&.update 'Detecting headers/footers'

      # Normalize by collapsing digits (page numbers) to '<d>' token so that
      # "Psychotherapy Guidebook 10" and "Psychotherapy Guidebook 11" count as
      # the same footer line.
      norm = ->(s) { s.downcase.gsub(/\d+/, '<d>').gsub(/\s+/, ' ').strip }

      # Heuristic: any line appearing in >30% of pages (case-insensitive) among
      # the first/last 2 lines is considered header/footer.
      hdrf_counts = Hash.new(0)
      total_pages = pages_lines.size
      pages_lines.each do |p|
        cand = (p[:lines].first(2) + p[:lines].last(2)).map(&norm).reject(&:empty?)
        cand.each { |l| hdrf_counts[l] += 1 }
      end
      threshold = (total_pages * 0.3).ceil
      hdrf_set = hdrf_counts.select { |_, c| c >= threshold }.keys

      transcription = { metadata: { pages: [] }, content: { paragraphs: [] } }

      pages_lines.each do |p|
        clean_lines = p[:lines].reject { |l| hdrf_set.include?(norm.call(l)) }

        # Break into paragraphs by blank lines (empty strings) preserving structure.
        buf = []
        add_para = lambda do |paragraph_lines|
          return if paragraph_lines.empty?
          text = paragraph_lines.join(' ').strip
          return if text.empty?
          transcription[:content][:paragraphs] << {
            text: text,
            page_numbers: [p[:num]],
            merged: false,
            kind: 'text'
          }
        end

        clean_lines.each do |line|
          if line.strip.empty?
            add_para.call(buf)
            buf = []
          else
            buf << line.strip
          end
        end
        add_para.call(buf)

        transcription[:metadata][:pages] << { page_number: p[:num] }
      end

      stl&.update 'Merging paragraphs'
      # Merge across pages using backend-agnostic helpers.
      blocks = Ocr.util.merge_paragraphs(transcription[:content][:paragraphs])
      transcription[:content][:paragraphs] = blocks

      # Reuse Ollama's language detection if available.
      stl&.update 'Detecting language'
      if defined?(Ocr::Ollama) && Ocr::Ollama.respond_to?(:detect_language)
        transcription[:metadata][:language] = Ocr::Ollama.detect_language(blocks)
      end

      stl&.update 'Saving transcription'
      File.write json_path, JSON.pretty_generate(transcription)
      stl&.update 'Done'
    end
  end
end 