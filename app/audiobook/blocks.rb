module Audiobook
  # Rejoins a paragraph the page broke in half. The detector draws the blocks a page shows;
  # what it cannot see is a sentence that runs over the foot of one page onto the next.
  class Blocks
    def self.merge(items) = new(items).merge

    def initialize(items)
      @items = items
    end

    def merge
      @items.each_with_object([]) do |entry, merged|
        previous = merged.last
        texts    = boundary(previous, entry) if paragraph?(previous) && paragraph?(entry)
        next merged << entry unless texts && resumes?(previous, entry, texts)

        join(previous, entry, texts)
      end
    end

    private

    def resumes?(previous, entry, texts)
      return false if entry.toc || previous.toc
      # Where the source drew the blocks there is no page break for a paragraph to straddle.
      return false if separate_blocks?(previous, entry)
      return false unless same_language?(previous, entry)
      return false unless carries_on?(previous, entry, texts)
      return false unless font_close?(previous, entry) || (texts.unfinished && texts.continuation)

      (texts.unfinished && !texts.last.empty?) || (texts.continuation && !texts.first.empty?)
    end

    # A lowercase resumption overrides the blocks the detector drew; an unfinished sentence only
    # carries over a page break, and a list entry or a lead-in label carries over nothing.
    def carries_on?(previous, entry, texts)
      return true if texts.continuation
      return false if texts.separate

      texts.unfinished && entry.page != (previous.last_page || previous.page)
    end

    def boundary(previous, entry)
      last  = previous.item.sentences.last&.text.to_s.strip
      first = entry.item.sentences.first&.text.to_s.strip

      SymMash.new(
        last:         last,
        first:        first,
        unfinished:   !Text::Punctuation.closes?(last),
        continuation: Text.lowercase?(first) && !ListMark.enumerated?(first),
        # A list entry opens its own block, and a lead-in or a numbered label names the block
        # that follows rather than running into it. A page break undoes none of that.
        separate:     ListMark.enumerated?(first) || ListMark.bulleted?(first) ||
          last.end_with?(':') || label_only?(last)
      )
    end

    def join(previous, entry, texts)
      if texts.unfinished && !texts.first.empty?
        join_sentences(previous.item, entry.item)
      else
        previous.item.sentences.concat(entry.item.sentences)
      end
      previous.last_page = entry.page
    end

    # The sentence the page broke becomes one again, references and all.
    def join_sentences(previous, item)
      last, first = previous.sentences.last, item.sentences.first
      return previous.sentences.concat(item.sentences) unless last && first

      last.text = [last.text, first.text].join(' ').gsub(/\s+/, ' ').strip
      Array(first.references).each { |reference| last.add_reference(reference) }
      previous.sentences.concat(item.sentences.drop(1))
    end

    def paragraph?(entry) = entry&.item.is_a?(Paragraph) && entry.item.sentences.any?

    def separate_blocks?(previous, entry) = !!(previous.block && entry.block && previous.block != entry.block)

    def same_language?(previous, entry)
      previous.item.sentences.last&.language == entry.item.sentences.first&.language
    end

    def font_close?(previous, entry)
      return true unless entry.font_size && previous.font_size

      FontRoles.same_size?(entry, previous)
    end

    # "e. Compromised immune system" names the block that follows; it does not run into it.
    def label_only?(text) = ListMark.enumerated?(text) && !Text::Punctuation.closes?(text)
  end
end
