class Subtitler
  class Subtitle
    # The text translated in batches, with the entries rebuilt around the translation.
    module Translation
      def translate!(from:, to:, merge_adjacent: true, translator: nil, batch_size: nil, status: nil)
        sentences = sentence_entries
        texts     = sentences.map(&:text)
        translated_texts = translate_texts(
          texts, from: from, to: to, translator: translator, batch_size: batch_size, status: status
        )

        sentences.zip(translated_texts).each do |entry, translated_text|
          entry.project_text!(self.class.clean_translation(translated_text))
        end
        replace_entries!(sentences)
        split_long_entries!(max_chars: MAX_ENTRY_CHARS)
        merge_adjacent!(max_chars: MAX_ENTRY_CHARS) if merge_adjacent
        replace_language!(to)
        rebuild_text_from_entries!
      end

      def translated(**options)
        deep_copy.translate!(**options)
      end

      def translate_srt!(from: nil, to:, translator: nil, batch_size: nil, status: nil)
        raise ArgumentError, 'subtitle source must be SRT' unless @metadata['source_format'] == 'srt'

        lines = @entries.flat_map { |entry| entry.metadata.fetch('content_lines') }
        masked, replacements, marker_pattern = protect_srt_timestamps(lines)
        translated_lines = translate_texts(
          masked, from: from, to: to, translator: translator, batch_size: batch_size, status: status
        )
        unless translated_lines.length == lines.length
          raise "SRT translation result count mismatch: expected #{lines.length}, got #{translated_lines.length}"
        end

        apply_translated_srt_lines(restore_srt_timestamps(translated_lines, replacements, marker_pattern))
        replace_language!(to)
        rebuild_text_from_entries!
      end

      def reject_noise!
        rejected_blocks = Array(@metadata['source_blocks']).each_index.select do |index|
          noise_content_lines(@metadata['source_blocks'].fetch(index)).any? do |line|
            line.strip.match?(NOISE_DOTS_LINE)
          end
        end
        reject_entries! do |entry|
          lines = Array(entry.metadata['content_lines'])
          lines.any? { |line| line.strip.match?(NOISE_DOTS_LINE) }
        end
        @metadata = Values.immutable_copy(Values.mutable_copy(@metadata).merge('rejected_block_indices' => rejected_blocks))
        rebuild_text_from_entries!
      end

      private

      def restore_srt_timestamps(texts, replacements, marker_pattern)
        texts.zip(replacements).map do |text, line_replacements|
          expected = line_replacements.map(&:first)
          actual   = text.to_s.scan(marker_pattern)
          unless actual == expected
            raise "SRT translation corrupted inline timestamps: expected #{expected.join(', ')}"
          end

          values = line_replacements.to_h
          text.to_s.gsub(marker_pattern) { |marker| values.fetch(marker) }
        end
      end

      def apply_translated_srt_lines(translated_lines)
        source_blocks = Values.mutable_copy(@metadata.fetch('source_blocks'))
        cursor        = 0
        @entries.each do |entry|
          count = entry.metadata.fetch('content_lines').length
          translate_srt_entry(entry, translated_lines.slice(cursor, count), source_blocks)
          cursor += count
        end
        @metadata = Values.immutable_copy(Values.mutable_copy(@metadata).merge('source_blocks' => source_blocks))
      end

      def translate_srt_entry(entry, content_lines, source_blocks)
        translated_text = Cues.semantic_text(content_lines.join("\n"))
        words = Cues.inline_timed_words(content_lines.join("\n"), entry.start, entry.finish, entry.cue_id)
        entry.replace_text!(translated_text)
          .replace_words!(words)
          .replace_source!(text: translated_text, words: words.map(&:deep_copy))
        entry.replace_metadata!(Values.mutable_copy(entry.metadata).merge(
          'content_lines' => content_lines,
          'ass_text'      => CGI.unescapeHTML(content_lines.join("\n")).gsub(Subtitler::Timestamps::INLINE_TIMESTAMP, ''),
          'source_text'   => translated_text
        ))
        block_index = entry.metadata.fetch('block_index')
        block_end   = source_blocks.fetch(block_index)[/(?:\r?\n)+\z/].to_s
        source_blocks[block_index] = original_srt_lines(entry).join(@metadata.fetch('line_ending')) + block_end
      end

      def protect_srt_timestamps(lines)
        prefix = nil
        loop do
          candidate = "__SRT_TS_#{SecureRandom.hex(8)}_"
          unless lines.any? { |line| line.include?(candidate) }
            prefix = candidate
            break
          end
        end
        marker_pattern = /#{Regexp.escape(prefix)}\d+__/
        index = 0
        replacements = []
        masked = lines.map do |text|
          line_replacements = []
          protected_text = text.gsub(Subtitler::Timestamps::INLINE_TIMESTAMP) do |timestamp|
            marker = "#{prefix}#{index}__"
            index += 1
            line_replacements << [marker, timestamp]
            marker
          end
          replacements << line_replacements
          protected_text
        end
        [masked, replacements, marker_pattern]
      end

      def translate_texts(texts, from:, to:, translator:, batch_size:, status: nil)
        service = translator || ::Translator
        ::Translator.in_batches(texts, progress: ::Translator.progress(texts.size, status), batch_size: batch_size) do |slice|
          service.translate(slice, from: from, to: to)
        end
      end

      def noise_content_lines(block)
        block.lines.reject do |line|
          stripped = line.strip
          stripped.empty? || stripped.match?(/^\d+$/) || line.include?('-->')
        end
      end
    end
  end
end
