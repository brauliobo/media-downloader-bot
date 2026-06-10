require 'roda'
require 'json'
require 'rack/utils'
require 'tmpdir'
require_relative '../../utils/safety'

module Bot
  module Worker
    class HTTPService < Roda
      plugin :json
      plugin :json_parser

      UPLOAD_PATH_KEYS = %i[file_path audio_path video_path document_path thumb_path thumbnail_path].freeze

      def self.create(service)
        Class.new(self) do
          define_method :service do
            service
          end
        end
      end
      
      def self.start(service, port, host: default_host)
        host      = bind_host(host)
        app_class = create(service)

        Thread.new do
          require 'puma'
          server = Puma::Server.new(app_class.freeze.app)
          begin
            server.add_tcp_listener(host, port)
          rescue Errno::EADDRINUSE
            puts "Port #{port} in use, trying #{port + 1}..."
            port += 1
            retry
          end
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

      def request_params(r)
        normalize_params(r.params)
      end

      def normalize_params(params)
        params = params.dup
        params.delete_if { |_, v| v.nil? }
        params.symbolize_keys
      end

      def authorized?(r)
        token = ENV['BOT_HTTP_TOKEN']
        return true if token.to_s.empty?

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
        ENV.fetch('BOT_ALLOWED_PATH_ROOTS', Dir.tmpdir).split(':').map { |root| File.expand_path(root) }
      end

      def require_allowed_path!(path)
        return unless path

        expanded = File.expand_path(path)
        raise ArgumentError, "path outside allowed roots: #{path}" unless Utils::Safety.inside_any?(expanded, allowed_roots)
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
        r.halt [401, {'Content-Type' => 'application/json'}, [{error: 'unauthorized'}.to_json]] unless authorized?(r)

        r.get 'queue/dequeue' do
          timeout = r.params['timeout']&.to_f
          job = service.dequeue(timeout: timeout)
          job ? {job: job, service_uri: service.bot_service_uri} : {job: nil}
        end

        r.get 'queue/size' do
          {size: service.queue_size}
        end

        r.post 'send_message' do
          params, msg = message_params(r)
          require_allowed_paths!(params, UPLOAD_PATH_KEYS)
          text = params.delete(:text)
          result = service.bot.send_message(msg, text, **params)
          result.to_h
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
          require_allowed_path!(params[:dir]) if params[:dir]
          result = service.bot.download_file(file_id_or_info, **params)
          {path: result}
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
