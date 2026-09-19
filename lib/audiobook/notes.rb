require_relative 'paragraph'
require_relative 'reference'
require_relative 'heading'
require_relative 'endnotes'
require_relative '../text_helpers'

module Audiobook
  # Binds footnote calls to the notes they point at. A call is either a raised marker inside a
  # sentence or a bare number set on its own line, and the note is the small-print paragraph
  # that repeats that number further down the page.
  class Notes
    FOOTNOTE_FONT_MARGIN = 1.0
    NOTE_OPENING = /\A(\d{1,3})[)\.]?\s+(.*)\z/m

    def self.attach(items, endnotes: Endnotes.none) = new(items, endnotes: endnotes).attach

    def initialize(items, endnotes: Endnotes.none)
      @items = items
      @endnotes = endnotes
      @body_font = body_font_by_page(items)
      @refs = SymMash.new { |hash, page| hash[page] = SymMash.new }   # { page => { '5' => Reference } }
      @pending = SymMash.new { |hash, page| hash[page] = [] }
      # A marker between the lines of a paragraph has no finished sentence to hang from yet, so
      # it waits for the first sentence of the paragraph that follows it on the same page.
      @deferred = SymMash.new { |hash, page| hash[page] = [] }
      @last_ref = {}
      @last_para = {}
    end

    def attach
      call_inline_markers
      collect_notes(mark_calls).tap { |items| bind_endnotes(items) }
    end

    private

    # A note gathered at the back of the book fills the call that pointed at it, looked up under
    # the chapter in force where the call was made because the numbering restarts with each.
    def bind_endnotes(items)
      return if @endnotes.empty?

      chapter    = nil
      @group_idx = 0
      @last_id   = nil
      items.each do |entry|
        chapter = chapter_number(entry.item) || chapter
        references_of(entry.item).each { |reference| bind(reference, chapter) }
      end
    end

    def chapter_number(item)
      item.text[Endnotes::GROUP_NUMBER, 1] if item.is_a?(Heading)
    end

    def references_of(item)
      return [] unless item.is_a?(Paragraph)

      item.sentences.flat_map(&:references)
    end

    # The numbering restarts with each chapter, so a call that does not carry on from the one
    # before it is the first of the next group the section lists. That ordinal is all there is to
    # go on in a book whose chapters are titled rather than numbered.
    def bind(reference, chapter)
      @group_idx += 1 if @last_id && reference.id.to_i <= @last_id.to_i
      @last_id = reference.id
      return unless reference.sentences.empty?

      text = @endnotes.entry(chapter, reference.id, @group_idx)
      reference.add_sentences(Sentence.build_all(TextHelpers.split_sentences(text))) if text.present?
    end

    # A call glued to a word or its punctuation, "Troyes.1" or "Eschenbach2".
    def call_inline_markers
      paragraphs.each do |entry|
        entry.item.sentences.each do |sentence|
          marker_ids(sentence).each { |id| open(entry.page, id, sentence) }
        end
      end
    end

    # A bare number on its own line calls the note that follows it.
    def mark_calls
      @items.each_with_object([]) do |entry, kept|
        ids = call_ids(entry)
        next kept << remember(entry) unless ids.present?

        ids.each { |id| mark_call(entry, id, kept.size) }
      end
    end

    def mark_call(entry, id, index)
      # A section of notes repeats the marker pages after the call was made, so the reference it
      # opens is the one still waiting behind it rather than a new call made here.
      waiting = @refs[entry.page].key?(id) ? nil : open_call_before(entry.page, id)
      called  = waiting || @refs[entry.page].key?(id)
      ref     = @refs[entry.page][id] ||= waiting || Reference.new(id)
      # Below the body the marker only opens its note; the call was already made inline.
      ref     = attach_call(entry.page, id, ref) unless called && (waiting || note_font?(entry))

      @last_ref[entry.page] = ref
      @pending[entry.page] << SymMash.new(ref: ref, min_idx: index)
    end

    def attach_call(page, id, ref)
      last = @last_para[page]&.sentences&.last
      return ref.tap { @deferred[page] << ref } unless TextHelpers.ends_with_punctuation?(last&.text)

      @refs[page][id] = last.add_reference(ref) || ref
    end

    # Remembers the paragraph a later call can hang from, and pays out any deferred calls.
    def remember(entry)
      return entry unless entry.item.is_a?(Paragraph)

      pay_deferred(entry.page, entry.item.sentences)
      @last_para[entry.page] = entry.item
      entry
    end

    def pay_deferred(page, sentences)
      refs = @deferred[page]
      return if refs.empty? || sentences.empty?

      sentences.each { |sentence| sentence.add_reference(refs.shift) if refs.any? }
      refs.each { |ref| sentences.last.add_reference(ref) }
      @last_ref[page] = sentences.last.references&.last || @last_ref[page]
      refs.clear
    end

    # The note itself: small print that repeats its marker, and the paragraphs that carry it on.
    def collect_notes(items)
      items.each_with_index.each_with_object([]) do |(entry, idx), kept|
        kept << entry unless consume_note(entry, idx)
      end
    end

    def consume_note(entry, idx)
      return false unless entry.item.is_a?(Paragraph) && entry.item.sentences.any?
      # A marker is a label; the note it points at has words in it. Where a book prints the
      # marker on its own line, the line after it is the note and the line itself is not.
      return false if entry.item.sentences.all? { |sentence| TextHelpers.marker_line?(sentence.text) }
      # Small print is what marks a note out on a page of body text. On a page that is nothing
      # but notes there is no smaller print, and the marker opened just above says it instead.
      return false unless note_font?(entry) || @pending[entry.page].any?

      queue = @pending[entry.page]
      # A note repeats its marker before the text; a body-sized paragraph that opens with a
      # number is a list entry instead, which is why the small print is checked first.
      opening = entry.item.sentences.first.text.match(NOTE_OPENING)
      ref = @refs[entry.page][opening[1]] || open_call_before(entry.page, opening[1]) if opening

      return fill(entry, ref, opening, idx, queue) if ref
      return carry(entry, queue.find { |info| info.min_idx <= idx }, idx) if queue.any? { |info| info.min_idx <= idx }

      append(entry, @last_ref[entry.page])
    end

    def fill(entry, ref, opening, idx, queue)
      queue.find { |info| info.ref.equal?(ref) }&.then { |info| info.min_idx = idx + 1 }
      entry.item.sentences.first.text = opening[2]
      ref.add_sentences(entry.item.sentences)
      queue.reject! { |info| info.ref.equal?(ref) && info.min_idx <= idx }
      @last_ref[entry.page] = ref
      true
    end

    def carry(entry, info, idx)
      info.min_idx = idx + 1
      info.ref.add_sentences(entry.item.sentences)
      @last_ref[entry.page] = info.ref
      @pending[entry.page].delete(info)
      true
    end

    def append(entry, ref)
      return false unless ref && @pending[entry.page].blank?

      ref.add_sentences(entry.item.sentences)
      true
    end

    # A book that gathers its notes at the end of a chapter prints them pages after the call, so
    # a note whose own page made no such call answers the nearest call still waiting behind it.
    def open_call_before(page, id)
      pages = @refs.keys.select { |other| other.to_i < page.to_i && unbound?(@refs[other][id]) }
      @refs[pages.max_by(&:to_i)][id] if pages.any?
    end

    def unbound?(reference) = reference && reference.sentences.empty?

    def open(page, id, sentence)
      ref = @refs[page][id] ||= Reference.new(id)
      sentence.add_reference(ref)
      @last_ref[page] = ref
    end

    def paragraphs = @items.select { |entry| entry.item.is_a?(Paragraph) }

    # Geometry-detected markers are exact; text heuristics only run for sources without positions.
    def marker_ids(sentence)
      return sentence.reference_ids if sentence.reference_ids.any?

      text, ids = TextHelpers.strip_inline_markers(sentence.text)
      sentence.text = text if text != sentence.text
      ids
    end

    def call_ids(entry)
      ids = marker_line_ids(entry.item)
      # A bare number at body size that nothing called is a stray figure, not a note label.
      return ids if ids.nil? || note_font?(entry)

      ids.select { |id| @refs[entry.page].key?(id) || open_call_before(entry.page, id) }
    end

    def marker_line_ids(item)
      value = case item
              when Paragraph then item.sentences.first.text if item.sentences.size == 1
              when Heading   then item.text
              end
      value.to_s.strip.then { |text| text.scan(/\d+/) if TextHelpers.marker_line?(text) }
    end

    def note_font?(entry)
      body = @body_font[entry.page]
      body && entry.font_size && entry.font_size.to_f < body.to_f - FOOTNOTE_FONT_MARGIN
    end

    # The body font of a page is the size most of its paragraphs are set in.
    def body_font_by_page(items)
      items.each_with_object(SymMash.new { |hash, page| hash[page] = SymMash.new }) do |entry, counts|
        next unless entry.item.is_a?(Paragraph) && entry.font_size

        size = (entry.font_size.to_f * 10).round / 10.0
        counts[entry.page][size] = counts[entry.page][size].to_i + 1
      end.each_with_object(SymMash.new) do |(page, counts), body|
        body[page] = counts.to_a.max_by { |_, count| count }&.first
      end
    end
  end
end
