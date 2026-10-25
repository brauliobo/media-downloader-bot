require 'find'

module Processors
  class Folder
    include Inputs
    include Originals

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

    def process_entry(entry)
      return if archive_output?(entry.path)

      entry.out_dir ||= Utils::Tmp.dir('mediazip-')
      FileUtils.mkdir_p entry.out_dir
      started_at = Time.now

      fake_msg = Bot::MsgHelpers.fake_msg
      fake_msg.bot = bot
      Processors::LocalFile.attach_to_message(fake_msg, entry.path, opts: entry_option_args(entry))

      Worker.new(fake_msg, workdir_path: entry.out_dir).process
      finish_entry(entry, started_at)
      delete_original(entry, started_at) if delete_originals? && !replace?
    ensure
      cleanup_replace(entry)
    end

    def entry_option_args(entry)
      return option_args unless camera?

      option_args + Presets::Camera.tier_args(entry.path, opts)
    end

    def jobs
      [opts.jobs.to_i, 1].max
    end

  end
end
