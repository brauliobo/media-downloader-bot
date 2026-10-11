module Processors
  class Folder
    # What happens to the original of a converted file: replaced, deleted or kept.
    module Originals
      private

      def delete_originals?
        enabled?(:delete_originals, :delete_original, :rm_originals, :rm_original)
      end

      def replace?
        enabled?(:replace, :replace_originals, :in_place)
      end

      def enabled?(*keys)
        keys.any? { |key| opts[key] }
      end

      def archive_output?(path)
        return false unless replace? && (opts.camera || opts.efficient)
        return false unless Presets::Camera.tier(path)[:noaudio]

        !Prober.audio_stream?(Prober.for(path))
      rescue
        false
      end

      def cleanup_replace(entry)
        return unless replace? && entry

        FileUtils.rm_f(output_path(entry.path, entry.out_dir))
        Dir.rmdir(entry.out_dir)
      rescue Errno::ENOENT, Errno::ENOTEMPTY
        nil
      end

      def delete_original(entry, started_at)
        return unless valid_output?(entry.path, entry.out_dir, started_at)

        if system('sudo', '-n', 'rm', '--', entry.path)
          puts "deleted original: #{entry.path}"
        else
          puts "delete original failed: #{entry.path}"
        end
      end

      def finish_entry(entry, started_at)
        return unless replace? && valid_output?(entry.path, entry.out_dir, started_at)

        FileUtils.mv(output_path(entry.path, entry.out_dir), entry.path, force: true)
        puts "replaced original: #{entry.path}"
      end

      def valid_output?(input_path, out_dir, started_at)
        converted_after?(output_path(input_path, out_dir), started_at) &&
          valid_media_file?(output_path(input_path, out_dir))
      end

      def output_path(input_path, out_dir)
        ::File.join(out_dir, ::File.basename(input_path))
      end

      def converted_after?(path, started_at)
        ::File.file?(path) && ::File.mtime(path) >= started_at && ::File.size?(path)
      end

      def valid_media_file?(path)
        probe = Prober.for(path)
        probe&.format&.duration.to_f.positive?
      rescue
        false
      end
    end
  end
end
