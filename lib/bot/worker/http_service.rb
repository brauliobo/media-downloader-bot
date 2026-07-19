require 'roda'
require 'puma'
require 'json'
require 'rack/utils'
require 'tmpdir'
require_relative '../../utils/safety'
require_relative '../message_result'

module Bot
  module Worker
    class HTTPService < Roda
      plugin :json
      plugin :json_parser

      UPLOAD_PATH_KEYS = %i[file_path thumb_path thumbnail_path].freeze

      def self.create(service)
        Class.new(self) do
          define_method :service do
            service
          end
        end
      end
      
      def self.start(service, port, host: default_host)
        host      = bind_host(host)
        raise ArgumentError, 'BOT_HTTP_TOKEN is required' if ENV['BOT_HTTP_TOKEN'].to_s.empty?
        raise ArgumentError, 'bot HTTP service must bind to loopback' unless loopback_host?(host)
        app_class = create(service)
        server = Puma::Server.new(app_class.freeze.app, nil, http_content_length_limit: 1024 * 1024)
        server.add_tcp_listener(host, port)

        Thread.new do
          puts "Bot HTTP service started on #{host}:#{port}"
          server.run
        end
      end

      def self.default_host
        ENV.fetch('BOT_HTTP_BIND', '').empty? ? '127.0.0.1' : ENV['BOT_HTTP_BIND']
      end

      def self.bind_host(host)
        host = host.to_s.strip
        host = default_host if host.empty?
        host.casecmp('localhost').zero? ? '127.0.0.1' : host
      end

      def self.loopback_host?(host)
        IPAddr.new(host).loopback?
      rescue IPAddr::InvalidAddressError
        false
      end

      def request_params(r)
        normalize_params(r.params)
      end

      def normalize_params(params)
        params = params.dup
        params.delete_if { |_, v| v.nil? }
        params.symbolize_keys
      end

      def authorized?(r)
        token = ENV['BOT_HTTP_TOKEN'].to_s
        return false if token.empty?

        Rack::Utils.secure_compare(auth_token(r), token)
      rescue
        false
      end

      def auth_token(r)
        header = r.get_header('HTTP_AUTHORIZATION').to_s
        token = header.delete_prefix('Bearer ')
        token.empty? ? r.get_header('HTTP_X_BOT_TOKEN').to_s : token
      end

      def allowed_roots
        roots = ENV.fetch('BOT_ALLOWED_PATH_ROOTS', Dir.tmpdir).split(':')
        roots << File.join(Dir.pwd, 'tmp')
        roots.map { |root| File.expand_path(root) }.uniq
      end

      def require_allowed_path!(path)
        return unless path

        allowed = allowed_roots.any? { |root| Utils::Safety.real_file_inside?(path, root) }
        raise ArgumentError, "path outside allowed roots: #{path}" unless allowed && !File.symlink?(path)
      end

      def require_allowed_directory!(path)
        real_path = File.realpath(path)
        allowed   = allowed_roots.filter_map { |root| File.realpath(root) rescue nil }
        raise ArgumentError, "directory outside allowed roots: #{path}" unless File.directory?(real_path) && Utils::Safety.inside_any?(real_path, allowed)
        raise ArgumentError, "symlinked directory is not allowed: #{path}" if File.symlink?(path)
      rescue Errno::ENOENT, Errno::EACCES
        raise ArgumentError, "invalid destination directory: #{path}"
      end

      def require_allowed_paths!(params, keys)
        keys.each { |key| require_allowed_path!(params[key]) }
      end

      def message_params(r)
        params = request_params(r)
        msg    = SymMash.new(params.delete(:msg))
        [params, msg]
      end

      route do |r|
        content_length = r.env['CONTENT_LENGTH'].to_i
        r.halt [413, {'Content-Type' => 'application/json'}, [{error: 'request too large'}.to_json]] if content_length > 1024 * 1024
        r.halt [401, {'Content-Type' => 'application/json'}, [{error: 'unauthorized'}.to_json]] unless authorized?(r)

        r.get 'queue/dequeue' do
          timeout = r.params['timeout']&.to_f
          job = service.dequeue(timeout: timeout)
          job ? {job: job, service_uri: service.bot_service_uri} : {job: nil}
        end

        r.get 'queue/size' do
          {size: service.queue_size}
        end

        r.get 'chat_messages' do
          params = request_params(r)
          params[:chat_id] = params[:chat_id].to_i
          params[:limit] = params[:limit].to_i if params[:limit]
          params[:from_message_id] = params[:from_message_id].to_i if params[:from_message_id]
          service.chat_messages(**params)
        end

        r.get 'chat_message' do
          params = request_params(r)
          params[:chat_id] = params[:chat_id].to_i
          params[:message_id] = params[:message_id].to_i
          service.chat_message(**params)
        end

        r.post 'max_caption' do
          {max_caption: service.max_caption}
        end

        r.post 'send_message' do
          params, msg = message_params(r)
          require_allowed_paths!(params, UPLOAD_PATH_KEYS)
          text = params.delete(:text)
          result = service.bot.send_message(msg, text, **params)
          result.to_h
        end

        r.post 'send_album' do
          params, msg = message_params(r)
          uploads = Array(params.delete(:uploads)).map { |up| SymMash.new(up) }
          uploads.each { |up| require_allowed_path!(up.fn_out) }
          text = params.delete(:text)
          result = service.bot.send_album(msg, text, uploads: uploads, **params)
          {messages: Array(result).map { |message| MessageResult.dump(message) }}
        end

        r.post 'edit_message' do
          params, msg = message_params(r)
          id = params.delete(:id)
          service.bot.edit_message(msg, id, **params)
          {success: true}
        end

        r.post 'delete_message' do
          params, msg = message_params(r)
          id = params.delete(:id)
          service.bot.delete_message(msg, id, **params)
          {success: true}
        end

        r.post 'download_file' do
          params = request_params(r)
          file_id_or_info = params.delete(:file_id_or_info)
          require_allowed_directory!(params[:dir]) if params[:dir]
          result = service.bot.download_file(file_id_or_info, **params)
          {path: result}
        end

        r.post 'edit_generated_message' do
          params = request_params(r)
          params[:chat_id] = params[:chat_id].to_i
          params[:message_id] = params[:message_id].to_i
          require_allowed_paths!(params, UPLOAD_PATH_KEYS)
          service.edit_generated_message(**params)
          {success: true}
        end

        r.post 'report_error' do
          params, msg = message_params(r)
          e = StandardError.new(params.delete(:e))
          e.define_singleton_method(:class) { OpenStruct.new(name: params.delete(:error_class)) }
          service.bot.report_error(msg, e, context: params.delete(:context))
          {success: true}
        end
      end

    end
  end
end
