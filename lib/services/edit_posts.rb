require 'drb/drb'
require 'faraday'
require 'fileutils'
require 'json'
require 'tmpdir'

require_relative '../worker'
require_relative 'concerns/edit_posts/capture_service'
require_relative 'concerns/edit_posts/http_manager'
require_relative 'concerns/edit_posts/post_selection'
require_relative 'concerns/edit_posts/regeneration'

module Services
  class EditPosts
    include PostSelection
    include Regeneration

    DEFAULT_LIMIT = 20
    DEFAULT_FETCH_LIMIT = 100
    SCRIPT_OPT_KEYS = %i[all apply channel chat drb fetch_limit from_message_id from_post http limit media order plan public query reply_to_pdf source source_urls start_at tmpdir].freeze

    def initialize(argv, manager: nil, output: $stdout)
      @manager = manager
      @output  = output
      @opts = argv.each_with_object({}) do |arg, opts|
        key, value = arg.split('=', 2)
        opts[key.tr('-', '_').to_sym] = value || true
      end
    end

    def run
      configure_worker_tmpdir
      manager = manager_service
      chat    = resolve_chat(manager)
      posts   = select_posts(fetch_posts(manager, chat)).first(limit)
      posts   = select_pdf_audio_replies(manager, chat, posts) if @opts[:reply_to_pdf].to_s == '1'

      @output.puts "chat=#{chat[:id]} title=#{chat[:title].inspect} posts=#{posts.size} apply=#{apply?}"
      posts.each.with_index(1) { |item, index| process_post(manager, chat, item, index) }
    end

    private

    def process_post(manager, chat, item, index)
      post, source = @opts[:reply_to_pdf].to_s == '1' ? item : [item, source_post(manager, chat, item)]
      @output.puts "#{index}. post=#{post[:id]} type=#{post[:type]} source=#{source_label(source)}"
      return if plan?

      upload = select_upload(post, regenerate(manager, chat, post, source))
      return @output.puts('  no generated upload captured') unless upload

      @output.puts "  generated type=#{upload[:type]} file=#{upload[:params][:"#{upload[:type]}_path"] || upload[:params][:file_path]}"
      return unless apply?

      manager.edit_generated_message(chat_id: chat[:id], message_id: post[:id], text: upload[:text], type: upload[:type], parse_mode: upload[:parse_mode], **upload[:params])
      @output.puts '  edited'
    end

    def configure_worker_tmpdir
      @tmpdir = @opts[:tmpdir] || File.join(Dir.pwd, 'tmp', 'edit_posts')
      FileUtils.mkdir_p(@tmpdir)
    end

    def manager_service
      return @manager if @manager

      http_uri = @opts[:http] || ENV['BOT_HTTP']
      return HTTPManager::Client.new(http_uri) if http_uri.present?

      DRbObject.new_with_uri(@opts[:drb] || ENV['BOT_DRB'] || 'druby://127.0.0.1:1188')
    end

    def limit = (@opts[:limit] || DEFAULT_LIMIT).to_i
    def fetch_limit = [limit, (@opts[:fetch_limit] || DEFAULT_FETCH_LIMIT).to_i].max
    def apply? = @opts[:apply].to_s == '1'
    def plan? = @opts[:plan].to_s == '1'

    def worker_opts_text
      @opts.reject { |key, _| SCRIPT_OPT_KEYS.include?(key) }
        .map { |key, value| value == true ? key.to_s : "#{key}=#{value}" }
        .join("\n")
    end
  end
end
