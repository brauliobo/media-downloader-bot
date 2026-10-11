class Subtitler
  class Subtitle
    class SemanticDiff
      # Differences in what WebVTT cues carry besides their text: identifier, settings and presentation.
      module VttMetadata
        private

        def compare_vtt_metadata(events, before_entry, after_entry, before_index, after_index)
          before_is_vtt = @before.metadata['source_format'].to_s == 'vtt'
          after_is_vtt  = @after.metadata['source_format'].to_s == 'vtt'
          return unless before_is_vtt || after_is_vtt

          before_identifier = before_is_vtt ? vtt_identifier(before_entry) : nil
          after_identifier  = after_is_vtt ? vtt_identifier(after_entry) : nil
          if before_identifier != after_identifier && (before_identifier || after_identifier)
            events << {
              type:             'cue_identifier_changed',
              before_index:     before_index,
              after_index:      after_index,
              before_identifier: before_identifier,
              after_identifier:  after_identifier,
            }
          end

          before_settings = before_is_vtt ? vtt_settings(before_entry) : nil
          after_settings  = after_is_vtt ? vtt_settings(after_entry) : nil
          if before_settings != after_settings && (before_settings || after_settings)
            events << {
              type:            'cue_settings_changed',
              before_index:    before_index,
              after_index:     after_index,
              before_settings: before_settings,
              after_settings:  after_settings,
            }
          end

          before_presentation = before_is_vtt ? vtt_presentation(before_entry) : nil
          after_presentation  = after_is_vtt ? vtt_presentation(after_entry) : nil
          if before_presentation != after_presentation &&
              (before_presentation || after_presentation)
            events << {
              type:                 'cue_presentation_changed',
              before_index:         before_index,
              after_index:            after_index,
              before_presentation:  before_presentation,
              after_presentation:   after_presentation,
            }
          end
        end

        def vtt_identifier(entry)
          if entry.metadata.key?('prefix_lines')
            identifier = Array(entry.metadata['prefix_lines']).reverse.find do |line|
              !line.to_s.strip.empty?
            end
            return normalize_identifier(identifier)
          end
          return if entry.metadata.key?('block_index')

          normalize_identifier(entry.cue_id)
        end

        def normalize_identifier(identifier)
          return if identifier.nil?

          value = identifier.to_s.strip
          value.empty? ? nil : value
        end

        def vtt_settings(entry)
          timing_line = entry.metadata['timing_line']
          return unless timing_line

          match = timing_line.match(
            /\A\s*#{Subtitler::Timestamps::TIMESTAMP_VALUE}\s+-->\s+#{Subtitler::Timestamps::TIMESTAMP_VALUE}(.*)\z/
          )
          return unless match

          value = match[1].to_s.strip.split.join(' ')
          value.empty? ? nil : value
        end

        def vtt_presentation(entry)
          return unless entry.metadata.key?('content_lines')

          Array(entry.metadata['content_lines']).map do |line|
            value = line.to_s.gsub(Subtitler::Timestamps::INLINE_TIMESTAMP, '')
            CGI.unescapeHTML(value).strip.split.join(' ')
          end
        end
      end
    end
  end
end
