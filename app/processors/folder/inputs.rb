module Processors
  class Folder
    # The media files a folder run converts, and the review of what it would do.
    module Inputs
      private

      def apply_presets
        Presets::Camera.apply(opts, option_args: option_args) if opts.camera || opts.efficient
      end

      def expand_inputs
        paths.flat_map { |path| path.to_s.split("\n") }.reject(&:blank?).flat_map do |path|
          path = ::File.expand_path(path)

          if ::File.directory?(path)
            expand_directory(path)
          elsif media_file?(path)
            entry(path)
          end
        end.compact
      end

      def expand_directory(path)
        Find.find(path).filter_map do |candidate|
          if ::File.directory?(candidate)
            Find.prune if candidate != path && ::File.basename(candidate) == 'converted'
            next
          end
          next unless media_file?(candidate)

          entry(candidate)
        end
      end

      def entry(path)
        SymMash.new(path: path, out_dir: output_dir_for(path))
      end

      def output_dir_for(path)
        return replace_dir_for(path) if replace?

        ::File.join(::File.dirname(path), 'converted')
      end

      def replace_dir_for(path)
        ::File.join(::File.dirname(path), '.mediazip-replace')
      end

      def media_file?(path)
        return false unless ::File.size?(path)

        ext = ::File.extname(path).downcase
        return false unless MEDIA_EXTENSIONS.include?(ext) ||
          Rack::Mime.mime_type(ext).then { |mime| mime&.start_with?('video/', 'audio/') }

        within_age?(path)
      end

      def review(entries)
        lines = [
          'folder media processing review',
          "inputs: #{entries.size} media file(s)",
          "output: #{replace? ? 'replace originals in place' : 'converted/ beside each input file'}",
          "options: #{option_args.join(' ')}",
        ]
        lines.concat(entries.first(20).map { |entry| "#{entry.path} -> #{entry.out_dir}" })
        lines << "... #{entries.size - 20} more" if entries.size > 20
        lines.join("\n")
      end

      def within_age?(path)
        age = Presets::Camera.age_days(path)
        min = opts.min_age&.to_i || opts.older_than&.to_i
        max = opts.max_age&.to_i || opts.newer_than&.to_i

        (!min || age >= min) && (!max || age <= max)
      end
    end
  end
end
