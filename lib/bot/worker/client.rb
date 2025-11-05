require 'drb/drb'
require 'faraday'
require 'json'

module Bot
  module Worker
    class Client
      def initialize(uri)
        @uri = uri
        if uri.start_with?('druby://')
          @drb = DRbObject.new_with_uri(uri)
          @mode = :drb
        elsif uri.start_with?('http://') || uri.start_with?('https://')
          @http_client = Faraday.new(url: uri) do |f|
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

      private

      def call(method, **kwargs)
        if @mode == :drb
          result = @drb.public_send(method, **kwargs)
          block_given? ? yield(result) : result
        else
          payload = kwargs.dup
          payload[:msg] = payload[:msg].to_h if payload[:msg] && payload[:msg].respond_to?(:to_h)
          payload[:file_id_or_info] = payload[:file_id_or_info].is_a?(Hash) ? payload[:file_id_or_info] : payload[:file_id_or_info].to_s if payload[:file_id_or_info]
          response = @http_client.post("/#{method}", payload)
          block_given? ? yield(response.body) : response.body
        end
      end
    end
  end
end

