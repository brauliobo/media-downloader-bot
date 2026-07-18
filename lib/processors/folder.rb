require 'find'
require_relative '../presets/camera'

module Processors
  class Folder
    MEDIA_EXTENSIONS = %w[
      .3g2 .3gp .aac .avi .flac .flv .m4a .m4v .mkv .mov .mp3 .mp4 .mpeg .mpg
      .mts .m2ts .ogg .opus .ts .wav .webm
    ].freeze

    def self.handles?(paths, _opts)
      paths.any? { |path| ::File.directory?(path) }
    end

    def initialize(paths:, opts:, option_args:, bot:)
      @paths = paths
      @opts = opts
      @option_args = option_args
      @bot = bot
    end

    def run
      apply_presets
      entries = expand_inputs
      raise 'No media files found' if entries.blank?

      if opts.review || opts.dryrun
        puts review(entries)
        return
      end

      Worker.skip_cleanup = true
      entries.peach(threads: jobs) { |entry| process_entry(entry) }
    end

    private

    attr_reader :paths, :opts, :option_args, :bot

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

    def process_entry(entry)
      Worker.workdir_path = entry.out_dir
      FileUtils.mkdir_p Worker.workdir_path
      started_at = Time.now

      fake_msg = Bot::MsgHelpers.fake_msg
      fake_msg.bot = bot
      Processors::LocalFile.attach_to_message(fake_msg, entry.path, opts: entry_option_args(entry))

      Worker.new(fake_msg).process
      finish_entry(entry, started_at)
      delete_original(entry, started_at) if delete_originals? && !replace?
    ensure
      cleanup_replace(entry)
    end

    def entry_option_args(entry)
      return option_args unless opts.camera || opts.efficient

      option_args + Presets::Camera.tier_args(entry.path, opts)
    end

    def delete_originals?
      enabled?(:delete_originals, :delete_original, :rm_originals, :rm_original)
    end

    def replace?
      enabled?(:replace, :replace_originals, :in_place)
    end

    def enabled?(*keys)
      keys.any? { |key| opts[key] }
    end

    def cleanup_replace(entry)
      return unless replace? && entry

      FileUtils.rm_f(output_path(entry.path, entry.out_dir))
      Dir.rmdir(entry.out_dir)
    rescue Errno::ENOENT, Errno::ENOTEMPTY
      nil
    end

    def within_age?(path)
      age = Presets::Camera.age_days(path)
      min = opts.min_age&.to_i || opts.older_than&.to_i
      max = opts.max_age&.to_i || opts.newer_than&.to_i

      (!min || age >= min) && (!max || age <= max)
    end

    def jobs
      [opts.jobs.to_i, 1].max
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
