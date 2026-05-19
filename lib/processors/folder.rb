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
      entries.each { |entry| process_entry(entry) }
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
          entry(path, output_dir_for(path))
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

        entry(candidate, output_dir_for(candidate))
      end
    end

    def entry(path, out_dir)
      SymMash.new(path: path, out_dir: out_dir)
    end

    def output_dir_for(path)
      ::File.join(::File.dirname(path), 'converted')
    end

    def media_file?(path)
      ext = ::File.extname(path).downcase
      MEDIA_EXTENSIONS.include?(ext) ||
        Rack::Mime.mime_type(ext).then { |mime| mime&.start_with?('video/', 'audio/') }
    end

    def review(entries)
      lines = [
        'folder media processing review',
        "inputs: #{entries.size} media file(s)",
        'output: converted/ beside each input file',
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
      Processors::LocalFile.attach_to_message(fake_msg, entry.path, opts: option_args)

      Worker.new(fake_msg).process
      delete_original(entry, started_at) if delete_originals?
    end

    def delete_originals?
      opts.delete_originals || opts.delete_original || opts.rm_originals || opts.rm_original
    end

    def delete_original(entry, started_at)
      output = converted_outputs(entry.out_dir, started_at).max_by { |path| ::File.mtime(path) }
      return unless output && valid_media_file?(output)

      FileUtils.rm_f(entry.path)
      puts "deleted original: #{entry.path}"
    end

    def converted_outputs(out_dir, started_at)
      Dir.glob(::File.join(out_dir, '*')).select do |path|
        ::File.file?(path) && ::File.mtime(path) >= started_at && ::File.size?(path)
      end
    end

    def valid_media_file?(path)
      probe = Prober.for(path)
      probe&.format&.duration.to_f.positive?
    rescue
      false
    end
  end
end
