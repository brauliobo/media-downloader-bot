require 'cgi'
require 'nokogiri'
require_relative 'book'

module Audiobook
  class Ewprs
    BODY_SELECTOR = [
      '.discourse_title', '.Para_Major_Heading', '.Para_Minor_Heading',
      '.Para_Indent', '.plain', '.Para_Sloka', '.Para_Translation_Eds',
      '.Para_Citation', '.Para_Quote', '.Para_Footnote', 'center'
    ].join(',').freeze
    UNAVAILABLE_BOOK = /unpublished in English|not yet published in any language|as yet unpublished in any language/i
    ONLINE_PLACEHOLDER = /\A\[To see if this discourse is now available online,/i

    Entry = Struct.new(:kind, :title, :path, :info, :sources, :book_refs, :chapters, keyword_init: true) do
      def slug = File.basename(path, File.extname(path))
    end

    attr_reader :root

    def initialize(root)
      @root = File.expand_path(root)
      raise ArgumentError, "EWPRS directory not found: #{root}" unless File.directory?(@root)
    end

    def discourses
      @discourses ||= begin
        nav = document(File.join(root, 'HTML/Navigation/alphabetical.html'))
        nav.css('.list_discourse_title').filter_map do |node|
          link = node.at('a[href]')
          next unless link

          info_node = node.next_element
          refs_node = info_node&.next_element
          refs = Array(refs_node&.css('a[href]')).map { |item| local_ref(item['href'], refs_node.document.url) }
          Entry.new(
            kind:      :discourse,
            title:     normalize(link.text),
            path:      local_ref(link['href'], nav.url).first,
            info:      normalize(info_node&.text),
            sources:   Array(refs_node&.css('a')).map { |item| normalize(item.text) },
            book_refs: refs
          )
        end.uniq(&:path)
      end
    end

    def available_discourses
      @available_discourses ||= discourses.select { |entry| available?(entry) }
    end

    def books
      @books ||= begin
        nav = document(File.join(root, 'HTML/Navigation/books_tocs.html'))
        nav.css('.books_book_title_tocs').filter_map do |node|
          link = node.at('a[href]')
          next unless link

          path = local_ref(link['href'], nav.url).first
          chapter_node = node.next_element
          chapters = Array(chapter_node&.css('a[href]')).map do |chapter|
            chapter_path, anchor = local_ref(chapter['href'], nav.url)
            [chapter_path, anchor, normalize(chapter.text)]
          end
          Entry.new(kind: :book, title: normalize(link.text), path: path, chapters: chapters)
        end.uniq(&:path).reject { |entry| entry.title.match?(UNAVAILABLE_BOOK) }
      end
    end

    def parse_options(entry)
      selector = entry.slug.match?(/Sarkars?_English_Grammar/) ? Audiobook::Parsers::Html::BLOCK_SELECTOR : BODY_SELECTOR
      SymMash.new(
        html_content_selector: selector,
        html_title_selector:   entry.kind == :discourse ? '.discourse_title' : '.book_title',
        html_language:         'en',
        html_block_comments:   !entry.slug.match?(/Sarkars?_English_Grammar/),
        instruct:              'male, middle-aged, moderate pitch'
      )
    end

    def chapter_discourses(book)
      refs = available_discourses.each_with_object({}) do |entry, index|
        entry.book_refs.each { |path, anchor| index[[path, anchor]] ||= entry }
      end
      book.chapters.filter_map { |path, anchor, _title| refs[[path, anchor]] }
    end

    def audit
      parsed = discourses.each_with_object({ available: 0, unavailable: 0, words: 0 }) do |entry, counts|
        text = body_text(entry)
        if available_text?(text)
          counts[:available] += 1
          counts[:words] += text.split.size
        else
          counts[:unavailable] += 1
        end
      end
      mapped = books.sum { |book| chapter_discourses(book).size }
      {
        discourses:             discourses.size,
        available_discourses:  parsed[:available],
        unavailable_discourses: parsed[:unavailable],
        discourse_words:       parsed[:words],
        books:                  books.size,
        book_chapters:          books.sum { |book| book.chapters.size },
        mapped_book_chapters:   mapped
      }
    end

    def find(title_or_slug)
      value = title_or_slug.to_s
      (discourses + books).find { |entry| entry.slug == value || entry.title.casecmp?(value) }
    end

    private

    def available?(entry)
      available_text?(body_text(entry))
    end

    def available_text?(text)
      text.present? && !text.match?(ONLINE_PLACEHOLDER)
    end

    def body_text(entry)
      data = Audiobook::Parsers::Html.extract_data(entry.path, opts: parse_options(entry))
      Array(data.content.lines).drop(1).map(&:text).join("\n")
    end

    def document(path)
      Nokogiri::HTML5.parse(Audiobook::Parsers::Html.read_html(path), path)
    end

    def local_ref(href, base)
      path, anchor = CGI.unescapeHTML(href.to_s).split('#', 2)
      [File.expand_path(CGI.unescape(path), File.dirname(base)), anchor]
    end

    def normalize(text)
      Audiobook::Parsers::Html.normalize(text)
    end
  end
end
