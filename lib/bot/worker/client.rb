require 'drb/drb'
require 'faraday'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../msg_helpers'

module Bot
  module Worker
    class Client
      include MsgHelpers

      def initialize(uri)
        @uri = uri
        if uri.start_with?('druby://')
          @drb = DRbObject.new_with_uri(uri)
          @mode = :drb
        elsif uri.start_with?('http://') || uri.start_with?('https://')
          @http_client = Faraday.new(url: uri, headers: {'Authorization' => "Bearer #{ENV.fetch('BOT_HTTP_TOKEN')}"}) do |f|
            f.request :json
            f.response :json
          end
          @mode = :http
        else
          raise ArgumentError, "Unsupported URI scheme: #{uri}"
        end
      end

      def send_message(msg, text, type: 'message', parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params)
        call(:send_message, msg: msg, text: text, type: type, parse_mode: parse_mode, delete: delete, delete_both: delete_both, **params) do |result|
          result.is_a?(Hash) ? SymMash.new(result) : result
        end
      end

      def send_album(msg, text, uploads:, parse_mode: 'MarkdownV2', delete: nil, delete_both: nil, **params)
        safe_uploads, cleanup_paths = safe_album_uploads(uploads)
        call(:send_album, msg: msg, text: text, uploads: safe_uploads, parse_mode: parse_mode, delete: delete, delete_both: delete_both, **params) do |result|
          message_results(result)
        end
      ensure
        Array(cleanup_paths).each { |path| FileUtils.rm_rf(path) }
      end

      def edit_message(msg, id, text: nil, type: 'text', parse_mode: 'MarkdownV2', **params)
        call(:edit_message, msg: msg, id: id, text: text, type: type, parse_mode: parse_mode, **params)
      end

      def delete_message(msg, id, wait: nil)
        call(:delete_message, msg: msg, id: id, wait: wait)
      end

      def download_file(file_id_or_info, priority: 32, offset: 0, limit: 0, synchronous: true, dir: nil)
        call(:download_file, file_id_or_info: file_id_or_info, priority: priority, offset: offset, limit: limit, synchronous: synchronous, dir: dir) do |result|
          result.is_a?(Hash) ? result['path'] || result[:path] : result
        end
      end

      def report_error(msg, e, context: nil)
        call(:report_error, msg: msg, e: e.to_s, error_class: e.class.name, context: context)
      end

      def max_caption
        @max_caption ||= call(:max_caption) { |r| r.is_a?(Hash) ? r[:max_caption] || r['max_caption'] : r }
      rescue
        self.class.max_caption
      end

      private

      def call(method, **kwargs)
        kwargs = normalize_kwargs(kwargs)

        if @mode == :drb
          result = @drb.public_send(method, **kwargs)
          block_given? ? yield(result) : result
        else
          payload = kwargs.dup
          payload[:msg] = payload[:msg].to_h if payload[:msg] && payload[:msg].respond_to?(:to_h)
          payload[:file_id_or_info] = payload[:file_id_or_info].is_a?(Hash) ? payload[:file_id_or_info] : payload[:file_id_or_info].to_s if payload[:file_id_or_info]
          response = @http_client.post("/#{method}", payload)
          raise "bot HTTP service returned #{response.status}" unless response.success?
          block_given? ? yield(response.body) : response.body
        end
      end

      def normalize_kwargs(kwargs)
        kwargs = kwargs.dup
        kwargs[:uploads] = Array(kwargs[:uploads]).map { |up| upload_payload(up) } if kwargs[:uploads]
        kwargs
      end

      def message_results(result)
        messages = result.is_a?(Hash) ? result[:messages] || result['messages'] : result
        Array(messages).map { |message| message.is_a?(Hash) ? SymMash.new(message) : message }
      end

      def upload_payload(upload)
        type = upload_value(upload, :type)
        type_name = upload_value(type, :name) if type

        {
          fn_out: upload_value(upload, :fn_out).to_s,
          mime:   upload_value(upload, :mime).to_s,
          type:   (type_name ? {name: type_name} : nil),
        }.compact
      end

      def upload_value(object, key)
        return object[key] || object[key.to_s] if object.is_a?(Hash)
        return object.public_send(key) if object.respond_to?(key)

        nil
      end

      def safe_album_uploads(uploads)
        FileUtils.mkdir_p(album_proxy_root)
        safe_dir      = Dir.mktmpdir('mdb-album-proxy-', album_proxy_root)
        cleanup_paths = [safe_dir]
        safe_uploads  = Array(uploads).map do |upload|
          payload = upload_payload(upload)
          source  = payload[:fn_out]
          next payload unless source && File.exist?(source)

          safe_path = safe_album_path(source, safe_dir)
          FileUtils.cp(source, safe_path)
          payload.merge(fn_out: safe_path)
        end

        [safe_uploads, cleanup_paths]
      end

      def safe_album_path(source, dir)
        File.join(dir, "#{Process.pid}-#{Time.now.to_f.to_s.tr('.', '')}-#{File.basename(source)}")
      end

      def album_proxy_root
        File.expand_path(File.join(Dir.pwd, 'tmp', 'album-proxy'))
      end
    end
  end
end
