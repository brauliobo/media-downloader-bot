require 'set'

module Audiobook
  # Turns the lines a parser extracted into the pages a narration reads: what of the book belongs
  # to the narration at all, what each size of its type is for, where its paragraphs divide, which
  # note answers which call, and what is left to say twice. A Book owns the file and its metadata;
  # this owns the one pass from lines to pages.
  class Assembly
    CHINESE_MAX_SENTENCE_CHARS = 30

    attr_reader :font_roles

    def initialize(metadata:, opts: nil, stl: nil, lang: nil, include_all: false)
      @metadata    = metadata
      @opts        = opts
      @stl         = stl
      @lang        = lang
      @include_all = include_all
    end

    def pages(lines_data, images_data = [])
      roles    = PageRoles.from_lines(lines_data) unless @include_all
      endnotes = roles ? Endnotes.from_lines(lines_data) : Endnotes.none
      lines    = Lines.build(narrated(lines_data, roles, endnotes))

      @font_roles = FontRoles.from_lines(lines)
      items = FontRoles.use(@font_roles) do
        Paragraph.discover_from_lines(lines, max_sentence_chars: max_sentence_chars)
      end.map { |entry| SymMash.new(entry) }

      build_pages(Repeats.strip(Blocks.merge(Notes.attach(items, endnotes: endnotes))), images_data)
    end

    private

    def narrated(lines_data, roles, endnotes)
      return lines_data unless roles

      PageFilter.narrated(lines_data, roles: roles, selected_pages: @metadata.selected_pages,
                          skip_pages: endnotes.pages)
    end

    def max_sentence_chars
      @lang == 'zh' ? CHINESE_MAX_SENTENCE_CHARS : Paragraph::Factory::MAX_SENTENCE_CHARS
    end

    def build_pages(items_with_pages, images_data)
      pages_hash = group_items_by_page(items_with_pages)
      add_images(pages_hash, images_data)
      # An empty page still takes its turn, so the narration keeps the book's numbering.
      page_numbers&.each { |page_num| pages_hash[page_num] ||= [] }

      pages_hash.sort.map { |page_num, items| Page.new(page_num, items) }
    end

    def page_numbers
      total = @metadata.page_count
      @metadata.selected_pages || (1.upto(total) if total)
    end

    # An image can share a page with text, and OCR happens as the Image is built.
    def add_images(pages_hash, images_data)
      total = @metadata.page_count
      added = Set.new
      images_data.each do |img_data|
        img_data = SymMash.wrap(img_data)
        next unless img_data.path && img_data.page
        next unless added.add?([img_data.page, img_data.path])

        context = SymMash.new(current: img_data.page, total: total) if total
        pages_hash[img_data.page] ||= []
        pages_hash[img_data.page] << Image.new(
          img_data.path, stl: @stl, page_context: context, text: img_data.text, opts: ocr_opts
        )
      end
    end

    def ocr_opts
      opts = SymMash.new(@opts || {})
      opts.lang ||= @metadata.language if @metadata.language
      opts
    end

    def group_items_by_page(items_with_pages)
      items_with_pages.each_with_object(SymMash.new { |h, k| h[k] = [] }) do |item_data, h|
        h[item_data.page] << item_data.item
      end
    end
  end
end
