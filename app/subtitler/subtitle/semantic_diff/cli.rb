require 'json'
require 'optparse'

class Subtitler
  class Subtitle
    class SemanticDiff
      # bin/subtitle_semantic_diff: compares two subtitle files and reports what changed in meaning.
      module CLI
      DEFAULT_TIME_TOLERANCE = 0.01
      DEFAULT_MAX_DETAILS    = 20

        module_function

        def run(argv)
          options = {
            format:            nil,
            time_tolerance:    DEFAULT_TIME_TOLERANCE,
            max_details:       DEFAULT_MAX_DETAILS,
            json:              false,
            fail_on_difference: false,
            help:              false,
          }
          parser = option_parser(options)

          begin
            parser.parse!(argv)
            if options[:help]
              puts parser
              return 0
            end
            raise OptionParser::MissingArgument, 'BEFORE and AFTER are required' unless argv.length == 2

            format = determine_format(argv, options[:format])
            before_path, after_path = argv
            before = load_subtitle(before_path, format)
            after  = load_subtitle(after_path, format)
            result = Subtitler::Subtitle::SemanticDiff.compare(
              before,
              after,
              time_tolerance: options[:time_tolerance],
              max_details:    options[:max_details],
            )

            if options[:json]
              puts JSON.pretty_generate(
                before:          before_path,
                after:           after_path,
                format:          format,
                time_tolerance:  options[:time_tolerance],
                max_details:     options[:max_details],
                comparison:      result,
              )
            else
              Report.print_human(
                before_path, after_path, format, options[:time_tolerance], result
              )
            end

            options[:fail_on_difference] && !result.fetch(:summary).fetch(:identical) ? 1 : 0
          rescue OptionParser::ParseError, ArgumentError, TypeError, KeyError, EncodingError, SystemCallError => error
            warn "error: #{error.message}"
            warn parser
            2
          end
        end

        def option_parser(options)
          OptionParser.new do |parser|
            parser.banner = 'Usage: bin/subtitle_semantic_diff BEFORE AFTER [options]'
            parser.on('--format FORMAT', 'subtitle format: srt or vtt') do |value|
              format = value.to_s.downcase
              raise ArgumentError, 'format must be srt or vtt' unless %w[srt vtt].include?(format)

              options[:format] = format
            end
            parser.on('--time-tolerance SECONDS', 'ignore timing deltas up to this value') do |value|
              tolerance = Float(value)
              raise ArgumentError, 'time-tolerance must be a finite non-negative number' unless tolerance.finite? && tolerance >= 0

              options[:time_tolerance] = tolerance
            end
            parser.on('--max-details N', 'limit reported examples') do |value|
              max_details = Integer(value, 10)
              raise ArgumentError, 'max-details must be a non-negative integer' if max_details.negative?

              options[:max_details] = max_details
            end
            parser.on('--json', 'write a machine-readable JSON report') { options[:json] = true }
            parser.on('--fail-on-difference', 'exit 1 when semantic differences exist') do
              options[:fail_on_difference] = true
            end
            parser.on('-h', '--help', 'show this help') { options[:help] = true }
          end
        end

        def determine_format(paths, override)
          return override if override

          formats = paths.map do |path|
            extension = File.extname(path).downcase.delete_prefix('.')
            extension if %w[srt vtt].include?(extension)
          end
          unless formats.all? && formats.uniq.length == 1
            raise ArgumentError, 'could not infer one subtitle format; use --format srt or --format vtt'
          end

          formats.first
        end

        def load_subtitle(path, format)
          text = File.read(path, encoding: 'BOM|UTF-8')
          raise Encoding::InvalidByteSequenceError, "#{path} is not valid UTF-8" unless text.valid_encoding?

          text = text.delete_prefix("\uFEFF")
          Subtitler::Subtitle.public_send("from_#{format}", text)
        end
      end
    end
  end
end
