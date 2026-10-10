module Audiobook
  # Title, author, language and narrator gender of a book, which the model reads out of a sample of its
  # opening pages.
  module Publication
    SAMPLE_PAGES = 5
    SCAN_PAGES   = 40
    TOC_LEADER   = /(?:\.{4,}|\s{3,})\s*\d{1,4}\s*\z/

    module_function

    # Fills in what the book does not say about itself and answers the gender of the narrator to use.
    def detect!(metadata, sample:, filename: nil, stl: nil)
      stl&.update 'Detecting book metadata'
      info = Language.book_metadata(Language.book_input(metadata, sample, filename: filename))
      metadata.title    = info['title']  if info['title'].present?
      metadata.author   = info['author'] if info['author'].present?
      metadata.language = info['lang']   if language_missing?(metadata) && info['lang'].to_s.match?(/\A[a-z]{2}\z/)
      info['gender'].presence || 'male'
    end

    def filename(metadata, opts) = opts&.source_base.presence || field(metadata, :source_name)

    def field(metadata, key) = metadata[key].presence || metadata[key.to_s].presence

    def language_missing?(metadata) = field(metadata, :language).blank?

    # What the book says in its first pages, once they have been assembled.
    def sample_from_pages(pages) = pages.first(SAMPLE_PAGES).flat_map(&:all_sentences).map(&:text).join("\n")

    # What a document says in its first pages, before anything has been assembled from it.
    def sample_from_data(data, opts:, stl:)
      sample_paragraphs(data, opts, stl).map { |para| para[:text] || para.text }.join("\n")
    end

    def sample_paragraphs(data, opts, stl)
      ordered = ordered_sample(data, opts, stl)
      return ordered if ordered.any?

      return [SymMash.new(text: data.content.text)] if data.content&.text
      return [SymMash.new(text: data.text)] if data.text

      []
    end

    def ordered_sample(data, opts, stl)
      return [] unless data.content

      texts  = text_items(data)
      images = Array(data.content.images).map { |img| SymMash.wrap(img) }
      return [] if texts.empty? && images.empty?

      sample_pages(texts, images).flat_map do |page|
        texts_for_page(texts, page) + image_texts_for_page(images, page, opts, stl)
      end.map { |text| SymMash.new(text: text) }
    end

    def text_items(data)
      lines = Array(data.content.lines).map { |item| SymMash.wrap(item) }
      return lines if lines.any?

      Array(data.content.paragraphs).map { |item| SymMash.wrap(item) }
    end

    def sample_pages(texts, images)
      pages = (texts + images).map { |item| page_for(item) }.compact.uniq.sort_by(&:to_i)
      texts_by_page = pages.first(SCAN_PAGES).index_with { |page| texts_for_page(texts, page) }
      select_pages(pages, texts_by_page)
    end

    # The opening pages worth sampling: a contents page says nothing about what the book is.
    def select_pages(pages, texts_by_page)
      ranked = pages.first(SCAN_PAGES)
      chosen = ranked.reject { |page| toc_like?(texts_by_page[page]) }
      (chosen.presence || ranked).first(SAMPLE_PAGES)
    end

    def toc_like?(texts)
      lines = Array(texts).map { |text| text.to_s.strip }.reject(&:empty?)
      return false if lines.size < 5

      leaders = lines.count { |line| line.match?(TOC_LEADER) }
      leaders >= 5 && leaders >= (lines.size * 0.3)
    end

    def texts_for_page(items, page)
      items.select { |item| page_for(item) == page }.filter_map { |item| item.text.to_s.strip.presence }
    end

    def image_texts_for_page(items, page, opts, stl)
      items.select { |item| page_for(item) == page }.filter_map { |item| ocr_text(item, opts, stl).strip.presence }
    end

    def ocr_text(image_data, opts, stl)
      return image_data.text.to_s if image_data.text.to_s.strip.present?
      return '' unless image_data.path

      OcrText.transcribe(image_data.path, stl: stl, opts: opts)
    end

    def page_for(item) = item.page || Array(item.page_numbers).first || 1
  end
end
