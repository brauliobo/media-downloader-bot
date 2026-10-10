module Audiobook
  module PageBoundaries
    module_function

    # A book loaded from YAML arrives already assembled, and the repetition of a line is all
    # that is left to go on. One assembled from lines has had its running heads and feet removed
    # already, while they were still lines and their place on the page could be read too.
    def strip!(pages)
      return if pages.size < 3

      page_candidates = pages.to_h do |page|
        [page, [page.items.first, page.items.last].compact.uniq.flat_map { |item| direct_sentences(item) }]
      end
      normalized_counts = Text.spread(page_candidates.values) { |sentence| Text.comparable_key(sentence.text) }
      exact_counts      = Text.spread(page_candidates.values) { |sentence| Text.comparable(sentence.text) }

      threshold = [(pages.size * 0.3).ceil, 3].max
      repeated_normalized = normalized_counts.select { |_, count| count >= threshold }.keys.to_set
      repeated_exact      = exact_counts.select { |_, count| count >= threshold }.keys.to_set
      return if repeated_normalized.empty?

      pages.each do |page|
        boundary_sentences = page_candidates.fetch(page).to_set
        page.items.reject! do |item|
          remove_item = prune_repeated_sentences!(item, boundary_sentences, repeated_normalized, repeated_exact)
          remove_item || (item.is_a?(Paragraph) && item.empty?)
        end
      end
    end

    def direct_sentences(item)
      item.is_a?(Sentence) ? [item] : Array(item.is_a?(Paragraph) ? item.sentences : nil)
    end

    def prune_repeated_sentences!(item, boundary_sentences, repeated_normalized, repeated_exact)
      if item.is_a?(Sentence)
        prune_repeated_references!(item, repeated_exact)
        return repeated_sentence?(item, boundary_sentences, repeated_normalized, repeated_exact)
      end
      return false unless item.is_a?(Paragraph)

      item.sentences.reject! do |sentence|
        prune_repeated_references!(sentence, repeated_exact)
        repeated_sentence?(sentence, boundary_sentences, repeated_normalized, repeated_exact)
      end
      false
    end

    def prune_repeated_references!(sentence, repeated_exact)
      sentence.references.each do |reference|
        reference.sentences.reject! do |referenced|
          prune_repeated_references!(referenced, repeated_exact)
          repeated_exact_sentence?(referenced, repeated_exact)
        end
      end
    end

    def repeated_sentence?(sentence, boundary_sentences, repeated_normalized, repeated_exact)
      repeated_exact_sentence?(sentence, repeated_exact) ||
        (boundary_sentences.include?(sentence) && repeated_normalized.include?(Text.comparable_key(sentence.text)))
    end

    def repeated_exact_sentence?(sentence, repeated_exact)
      text = Text.comparable(sentence.text)
      repeated_exact.any? { |candidate| text == candidate || (candidate.length >= 40 && text.include?(candidate)) }
    end
  end
end
