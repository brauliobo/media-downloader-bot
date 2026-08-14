require_relative '../boot'

require 'drb/drb'
require 'fileutils'
require 'json'
require 'telegram/bot'
require 'timeout'
require 'tmpdir'

module Services
  class EditPostThumbnails
    MESSAGE_ID_FACTOR = 1_048_576
    URL_PATTERN = %r{\Ahttps://t\.me/(?<username>[A-Za-z0-9_]+)/(?<post_id>\d+)(?:[?#].*)?\z}

    Target = Data.define(:url, :username, :post_id) do
      def message_id = post_id * MESSAGE_ID_FACTOR
    end

    def initialize urls:, thumbnail:, source: nil, manager: nil, resolver: nil, drb: nil, timeout: 7_200, tmpdir: nil,
                   output: $stdout, ffmpeg: FFmpeg.new
      @targets   = urls.map { |url| parse_target(url) }
      @thumbnail = File.expand_path(thumbnail)
      @source    = File.expand_path(source) if source
      @manager   = manager || DRbObject.new_with_uri(drb || ENV['BOT_DRB'] || 'druby://127.0.0.1:1188')
      @resolver  = resolver || method(:resolve_chat_id)
      @timeout   = timeout.to_f
      @tmpdir    = tmpdir
      @output    = output
      @ffmpeg    = ffmpeg
      @prepared  = {}
      raise ArgumentError, "thumbnail not found: #{@thumbnail}" unless File.file?(@thumbnail)
      raise ArgumentError, "source media not found: #{@source}" if @source && !File.file?(@source)
    end

    def run
      Dir.mktmpdir('edit-post-thumbnails-', @tmpdir) do |dir|
        FileUtils.chmod(0o755, dir)
        @runtime_thumbnail = File.join(dir, File.basename(@thumbnail))
        FileUtils.cp(@thumbnail, @runtime_thumbnail)
        targets.map { |target| edit(target, dir) }
      end
    end

    private

    attr_reader :targets, :manager, :resolver, :output, :ffmpeg

    def parse_target(url)
      match = url.to_s.match(URL_PATTERN)
      raise ArgumentError, "invalid public Telegram post URL: #{url.inspect}" unless match

      Target.new(url: url, username: match[:username], post_id: match[:post_id].to_i)
    end

    def edit(target, dir)
      chat_id = resolver.call(target.username)
      post = remote_call(:chat_message, chat_id: chat_id, message_id: target.message_id)
      raise "Telegram post not found: #{target.url}" unless post

      media = post.fetch(:media)
      raise "Telegram post has unsupported media: #{target.url}" unless %w[audio video document].include?(media[:kind].to_s)

      prepared = prepared_media(media, dir)
      params = edit_params(post, media, prepared)
      response = remote_call(:edit_generated_message, **params)
      result = {url: target.url, chat_id: chat_id, message_id: target.message_id, media: prepared, response: response}
      output.puts JSON.generate(result)
      result
    end

    def prepared_media(media, dir)
      key = media[:remote_id].presence || media.fetch(:file_id)
      @prepared[key] ||= begin
        downloaded = @source || remote_call(:download_file, media.fetch(:file_id), dir: dir)
        telegram_media(downloaded, media, dir)
      end
    end

    def telegram_media(path, media, dir)
      return path unless media[:kind].to_s == 'audio' && File.extname(path).downcase.in?(%w[.ogg .opus])

      output_path = File.join(dir, "#{File.basename(media[:file_name].to_s, '.*')}.m4a")
      ffmpeg.remux_audio input: path, output: output_path, label: 'Telegram audio remux failed'
    end

    def edit_params(post, media, path)
      params = {
        chat_id:        post.fetch(:chat_id),
        message_id:     post.fetch(:id),
        text:           post[:text].to_s,
        type:           media.fetch(:kind).to_sym,
        parse_mode:     nil,
        file_path:      path,
        thumbnail_path: @runtime_thumbnail,
        copy:            false,
      }
      params[:remote_id] = media[:remote_id] if media[:remote_id].present? && File.extname(path).downcase == File.extname(media[:file_name].to_s).downcase
      return params unless media[:kind].to_s == 'audio'

      params.merge(
        duration:  media[:duration].to_f.round,
        title:     File.basename(media[:file_name].to_s, '.*'),
        performer: '',
      )
    end

    def resolve_chat_id(username)
      @telegram ||= Telegram::Bot::Api.new(ENV.fetch('TG_BOT_TOKEN'))
      @telegram.get_chat(chat_id: "@#{username}").id
    end

    def remote_call(method, *args, **kwargs)
      Timeout.timeout(@timeout) { manager.public_send(method, *args, **kwargs) }
    rescue Timeout::Error
      raise Timeout::Error, "DRb #{method} timed out after #{@timeout.to_i}s"
    end
  end
end
