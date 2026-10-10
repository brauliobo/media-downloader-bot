require 'json'

class Subtitler
  class Subtitle
    class SemanticDiff
      # The comparison of two subtitles, written for a person to read.
      module Report
        module_function

        def print_human(before_path, after_path, format, tolerance, result)
          summary = result.fetch(:summary)
          puts 'Semantic subtitle comparison'
          puts "Before: #{before_path}"
          puts "After:  #{after_path}"
          puts "Format: #{format}"
          puts "Cues: #{summary.fetch(:before_cue_count)} before, #{summary.fetch(:after_cue_count)} after; " \
               "#{summary.fetch(:matched_cue_count)} matched, " \
               "#{summary.fetch(:unmatched_before_cue_count)} removed, " \
               "#{summary.fetch(:unmatched_after_cue_count)} added"
          if summary.fetch(:identical)
            puts "Result: identical within #{format_seconds(tolerance)} timing tolerance"
          else
            puts "Result: #{summary.fetch(:difference_count)} meaningful difference(s)"
            puts "Types: #{format_difference_types(summary.fetch(:differences_by_type))}"
          end
          puts "Max cue timing deltas: start #{format_seconds(summary[:max_start_delta])}, " \
               "finish #{format_seconds(summary[:max_finish_delta])}"
          puts "Max word timing deltas: start #{format_seconds(summary[:max_word_start_delta])}, " \
               "finish #{format_seconds(summary[:max_word_finish_delta])}"

          details = result.fetch(:details)
          if details.empty?
            puts 'Examples: none'
          else
            puts "Examples: #{details.length} of #{summary.fetch(:difference_count)}"
            details.each { |detail| puts "- #{format_detail(detail)}" }
            puts '- additional differences omitted' if result.fetch(:details_truncated)
          end
        end

        def format_difference_types(types)
          types.map { |type, count| "#{type}=#{count}" }.join(', ')
        end

        def format_detail(detail)
          case detail.fetch(:type)
          when 'cue_removed'
            "cue removed before ##{detail.fetch(:before_index)} #{quote(detail.fetch(:before_text))}"
          when 'cue_added'
            "cue added after ##{detail.fetch(:after_index)} #{quote(detail.fetch(:after_text))}"
          when 'text_changed'
            "cue ##{detail.fetch(:before_index)} text #{quote(detail.fetch(:before_text))} -> #{quote(detail.fetch(:after_text))}"
          when 'timing_changed'
            "cue ##{detail.fetch(:before_index)} timing start #{format_seconds(detail.fetch(:start_delta))}, " \
                 "finish #{format_seconds(detail.fetch(:finish_delta))}"
          when 'word_count_changed'
            "cue ##{detail.fetch(:before_index)} word count #{detail.fetch(:before_word_count)} -> #{detail.fetch(:after_word_count)}"
          when 'word_text_changed'
            "cue ##{detail.fetch(:before_index)} word text changed #{JSON.generate(detail.fetch(:changes))}"
          when 'word_timing_changed'
            "cue ##{detail.fetch(:before_index)} word timing changed #{JSON.generate(detail.fetch(:changes))}"
          when 'speaker_changed'
            "cue ##{detail.fetch(:before_index)} speaker #{detail[:before_speaker_id].inspect} -> #{detail[:after_speaker_id].inspect}"
          when 'cue_identifier_changed'
            "cue ##{detail.fetch(:before_index)} identifier #{quote(detail[:before_identifier])} -> #{quote(detail[:after_identifier])}"
          when 'cue_settings_changed'
            "cue ##{detail.fetch(:before_index)} settings #{quote(detail[:before_settings])} -> #{quote(detail[:after_settings])}"
          when 'cue_presentation_changed'
            "cue ##{detail.fetch(:before_index)} presentation #{JSON.generate(detail[:before_presentation])} -> " \
                 "#{JSON.generate(detail[:after_presentation])}"
          else
            JSON.generate(detail)
          end
        end

        def quote(value)
          JSON.generate(value)
        end

        def format_seconds(value)
          return 'n/a' if value.nil?

          text = format('%.6f', value).sub(/0+\z/, '').sub(/\.\z/, '')
          text = '0' if text == '-0'
          "#{text}s"
        end
      end
    end
  end
end
