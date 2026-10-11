class Subtitler
  class Subtitle
    # VTT and SRT documents read into a subtitle: cue timing, inline word timestamps and the
    # source text needed to write the document back unchanged.
    module Cues
      module_function

      def parse(input, format:)
        newline        = input.include?("\r\n") ? "\r\n" : "\n"
        normalized     = input.gsub(/\r\n?|\r/, "\n")
        validate_cue_document!(normalized, format)
        final_newlines = normalized[/\n*\z/].to_s.length
        blocks         = normalized.split(/\n\n+/)
        entries        = blocks.filter_map.with_index do |block, block_index|
          cue_from_block(block, block_index, format)
        end
        metadata = {
          'source_format'  => format.to_s,
          'line_ending'    => newline,
          'final_newlines' => final_newlines,
        }
        if format == :srt
          source_blocks = input.split(/\r?\n\r?\n+/)
          metadata.merge!(
            'source_blocks'      => source_blocks,
            'cue_block_indices'  => entries.map { |entry| entry.metadata.fetch('block_index') },
          )
        end
        Subtitle.new(
          text: entries.map(&:text).join(' '),
          entries: entries,
          metadata: metadata
        )
      end

      def cue_from_block(block, block_index, format)
        lines        = block.lines(chomp: true)
        timing_index = lines.index { |line| line.include?('-->') }
        return unless timing_index

        timestamps = lines.fetch(timing_index).scan(Subtitler::Timestamps::TIMESTAMP_VALUE)
        start_time = Subtitler.parse_timestamp(timestamps[0])
        finish_time = Subtitler.parse_timestamp(timestamps[1])
        return unless start_time && finish_time

        content_lines = lines[(timing_index + 1)..] || []
        raw_text      = content_lines.join("\n")
        text          = semantic_text(raw_text)
        return if text.empty?

        cue_id = lines[0...timing_index].reverse.find { |line| !line.strip.empty? }
        cue_id = block_index if format == :vtt && cue_id.nil?
        words  = inline_timed_words(raw_text, start_time, finish_time, cue_id)
        metadata = {
          'content_lines' => content_lines,
          'ass_text'      => CGI.unescapeHTML(raw_text).gsub(Subtitler::Timestamps::INLINE_TIMESTAMP, ''),
          'source_start'  => start_time,
          'source_finish' => finish_time,
          'source_text'   => text,
          'timing_line'   => lines.fetch(timing_index),
          'prefix_lines'  => lines[0...timing_index],
          'block_index'   => block_index,
        }
        metadata['source_signature'] = source_signature(
          start: start_time, finish: finish_time, text: text, cue_id: cue_id, words: words
        ) if format == :vtt
        Entry.new(
          start:  start_time,
          finish: finish_time,
          text:   text,
          words:  words,
          cue_id: cue_id,
          metadata: metadata
        )
      end

      def source_signature(start:, finish:, text:, cue_id:, words:)
        [
          start,
          finish,
          cue_id,
          text,
          words.map { |word| [word.text, word.start, word.finish] },
        ]
      end

      def inline_timed_words(text, cue_start, cue_finish, cue_id)
        timed = timed_markers(text)
        times = timed.map(&:last)
        return [] if timed.empty?
        return [] unless times.all? { |time| time >= cue_start && time <= cue_finish }
        return [] unless times.each_cons(2).all? { |left, right| right > left }

        boundaries = [cue_start, *times, cue_finish]
        words = marker_chunks(text, timed).each_with_index.map do |chunk, index|
          chunk_words(chunk, boundaries.fetch(index), boundaries.fetch(index + 1), index, cue_id)
        end
        words.any?(&:nil?) ? [] : words.flatten
      end

      # The inline timestamps of a cue with the time each carries; none when any of them is malformed.
      def timed_markers(text)
        tags = text.scan(/<([^>]*)>/).flatten
        return [] if tags.any? { |tag| tag.match?(/\A\d{1,2}:\d{2}/) && Subtitler.parse_timestamp(tag).nil? }

        text.to_enum(:scan, Subtitler::Timestamps::INLINE_TIMESTAMP).filter_map do
          match = Regexp.last_match
          time  = Subtitler.parse_timestamp(match[1])
          [match, time] if time
        end
      end

      # The text between the inline timestamps.
      def marker_chunks(text, timed)
        cursor = 0
        chunks = timed.map do |match, _time|
          text[cursor...match.begin(0)].tap { cursor = match.end(0) }
        end
        chunks << text[cursor..]
      end

      # The words of one chunk spread evenly over its time; nil when the chunk has no time to spread over.
      def chunk_words(chunk, start_time, finish_time, index, cue_id)
        tokens = semantic_text(chunk).split
        return [] if tokens.empty?
        return unless finish_time > start_time

        duration = finish_time - start_time
        tokens.map.with_index do |token, token_index|
          token_start  = start_time + duration * token_index / tokens.size
          token_finish = token_index == tokens.size - 1 ? finish_time : start_time + duration * (token_index + 1) / tokens.size
          Word.new(
            text: token,
            start: token_start,
            finish: token_finish,
            metadata: {'cue_id' => cue_id, 'marker' => index.positive? && token_index.zero?, 'marker_group' => index}
          )
        end
      end

      def validate_cue_document!(input, format)
        if format == :vtt
          header = input.each_line.first&.strip
          raise ArgumentError, 'invalid WEBVTT header' unless header&.match?(/\A\uFEFF?WEBVTT(?:[ \t].*)?\z/)
        end

        timing_lines = input.each_line.select do |line|
          if format == :vtt
            line.include?('-->')
          else
            line.match?(/\A\s*#{Subtitler::Timestamps::TIMESTAMP_VALUE}\s+-->/)
          end
        end
        timing_lines.each do |line|
          label = format == :vtt ? 'WEBVTT' : 'SRT'
          raise ArgumentError, "invalid #{label} cue timing" unless line.match?(Subtitler::Timestamps::CUE_TIMING)

          start_text, finish_text = line.scan(Subtitler::Timestamps::TIMESTAMP_VALUE).first(2)
          start_time  = Subtitler.parse_timestamp(start_text)
          finish_time = Subtitler.parse_timestamp(finish_text)
          unless start_time && finish_time && finish_time > start_time
            raise ArgumentError, "invalid #{label} cue range"
          end
        end
      end

      def semantic_text(text)
        plain = text.to_s.gsub(/<br\s*\/?\s*>/i, ' ').gsub(/<[^>]*>/, '')
        Nokogiri::HTML5.fragment(plain).text.split.join(' ')
      end
    end
  end
end
