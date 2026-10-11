class Subtitler
  class Subtitle
    # The entries written out as VTT, SRT or ASS, keeping an original cue as it came where nothing changed.
    module Rendering
      def to_vtt(word_tags: true)
        render_cues(format: :vtt, word_tags: word_tags)
      end

      def to_srt(word_tags: true)
        render_cues(format: :srt, word_tags: word_tags)
      end

      def to_ass(portrait: false, mode: :instagram, preset: 'default')

        Subtitler::Ass.document_for(self, portrait: portrait, mode: mode, preset: preset).to_s
      end

      private

      def render_cues(format:, word_tags:)
        decimal = format == :srt ? ',' : '.'
        out     = format == :vtt ? +"WEBVTT\n\n" : +''
        newline = format == :srt ? @metadata.fetch('line_ending', "\n") : "\n"
        if format == :srt && word_tags && @metadata['source_blocks'] && @entries.all? { |entry| original_srt_entry?(entry) }
          return render_original_srt_document
        end

        rendered = @entries.filter_map.with_index do |entry, index|
          source_start  = entry.start
          source_finish = entry.finish
          next unless source_finish > source_start

          if format == :srt && word_tags && original_srt_entry?(entry)
            next original_srt_lines(entry).join(newline)
          end

          start_units  = Subtitler.timestamp_units(source_start)
          finish_units = Subtitler.timestamp_units(source_finish)
          finish_units = start_units + 1 if finish_units <= start_units
          start_time   = start_units / 1000.0
          finish_time  = finish_units / 1000.0
          lines        = []
          lines.concat(cue_prefix_lines(entry, index, format))
          lines << cue_timing_line(entry, start_time, finish_time, decimal, format)
          lines << render_entry_text(entry, start_time, finish_time, decimal, word_tags, format)
          lines.join(newline)
        end

        if format == :vtt
          out << rendered.join("\n\n")
          out << "\n\n" unless rendered.empty?
        else
          out << rendered.join(newline * 2)
          out << newline * @metadata.fetch('final_newlines', rendered.empty? ? 0 : 2)
        end
        out
      end

      def cue_prefix_lines(entry, index, format)
        if format == :vtt
          return entry.metadata.fetch('prefix_lines') if entry.metadata.key?('prefix_lines')
          return [(index + 1).to_s] if @metadata['numbered_cues']

          return []
        end

        [cue_identifier(entry, index, format)].compact
      end

      def cue_identifier(entry, index, format)
        return (index + 1).to_s if format == :srt && entry.cue_id.nil?
        return entry.cue_id.to_s if format == :srt
        return unless @metadata['numbered_cues']

        (index + 1).to_s
      end

      def cue_timing_line(entry, start_time, finish_time, decimal, format)
        if format == :vtt && original_vtt_entry?(entry)
          return entry.metadata.fetch('timing_line')
        end

        settings = format == :vtt && @metadata['source_format'] == 'vtt' ? vtt_timing_settings(entry) : ''
        "#{Subtitler.format_timestamp(start_time, decimal: decimal)} --> #{Subtitler.format_timestamp(finish_time, decimal: decimal)}#{settings}"
      end

      def render_entry_text(entry, start_time, finish_time, decimal, word_tags, format)
        if format == :vtt && original_vtt_entry?(entry)
          content_lines = entry.metadata.fetch('content_lines')
          content_lines = content_lines.map { |line| line.gsub(Subtitler::Timestamps::INLINE_TIMESTAMP, '') } unless word_tags
          return content_lines.join("\n")
        end
        if format == :vtt && @metadata['source_format'] == 'srt' && original_srt_entry?(entry)
          return entry.metadata.fetch('content_lines').join("\n").gsub(Subtitler::Timestamps::INLINE_TIMESTAMP) do |timestamp|
            timestamp.tr(',', '.')
          end
        end
        return entry.text.strip if entry.words.empty?

        last_marker = nil
        preserve_markers = @metadata['source_format'] == 'srt'
        entry.words.filter_map.with_index do |word, index|
          token = word.text.strip
          next if token.empty?

          marker_units = Subtitler.timestamp_units(word.start)
          marker_time  = marker_units / 1000.0
          tagged = if preserve_markers
            word_tags && word.metadata['marker']
          elsif format == :srt
            word_tags && index.positive?
          else
            word_tags && marker_time >= start_time &&
              (index.positive? || marker_time > start_time) && marker_time < finish_time &&
              (!last_marker || marker_time > last_marker)
          end
          last_marker = marker_time if tagged
          marker = Subtitler.format_timestamp(marker_time, decimal: decimal)
          tagged ? "<#{marker}>#{token}" : token
        end.join(' ')
      end

      def original_vtt_entry?(entry)
        @metadata['source_format'] == 'vtt' &&
          entry.metadata['source_signature'] == Cues.source_signature(
            start: entry.start, finish: entry.finish, text: entry.text,
            cue_id: entry.cue_id, words: entry.words)
      end

      def vtt_timing_settings(entry)
        timing_line = entry.metadata['timing_line']
        return '' unless timing_line

        match = timing_line.match(/\A\s*#{Subtitler::Timestamps::TIMESTAMP_VALUE}\s+-->\s+#{Subtitler::Timestamps::TIMESTAMP_VALUE}(.*)\z/)
        match ? match[1] : ''
      end

      def original_srt_entry?(entry)
        entry.metadata['source_start'] == entry.start &&
          entry.metadata['source_finish'] == entry.finish &&
          entry.metadata['source_text'] == entry.text
      end

      def original_srt_lines(entry)
        Array(entry.metadata['prefix_lines']) +
          [entry.metadata.fetch('timing_line')] + entry.metadata.fetch('content_lines')
      end

      def render_original_srt_document
        kept_cues = @entries.map { |entry| entry.metadata.fetch('block_index') }
        cue_blocks = @metadata.fetch('cue_block_indices')
        rejected   = Array(@metadata['rejected_block_indices'])
        @metadata.fetch('source_blocks').filter_map.with_index do |block, index|
          next if rejected.include?(index)
          next if cue_blocks.include?(index) && !kept_cues.include?(index)

          block
        end.join("\n\n")
      end

      def derived_entry_copy(entry)
        entry.deep_copy.replace_metadata!(derived_metadata(entry.metadata))
      end

      def derived_metadata(metadata)
        Values.mutable_copy(metadata).reject do |key, _|
          RAW_CUE_METADATA_KEYS.include?(key.to_s)
        end
      end
    end
  end
end
