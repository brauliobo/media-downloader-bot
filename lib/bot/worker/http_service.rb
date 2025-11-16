require 'roda'
require 'json'

module Bot
  module Worker
    class HTTPService < Roda
      plugin :json
      plugin :json_parser

      def self.create(service)
        Class.new(self) do
          define_method :service do
            service
          end
        end
      end

      def normalize_params(params)
        params = params.dup
        params.delete_if { |_, v| v.nil? }
        params.symbolize_keys
      end

      route do |r|
        r.get 'queue/dequeue' do
          timeout = r.params['timeout']&.to_f
          job = service.dequeue(timeout: timeout)
          job ? {job: job, service_uri: service.bot_service_uri} : {job: nil}
        end

        r.get 'queue/size' do
          {size: service.queue_size}
        end

        r.post 'send_message' do
          params = normalize_params(r.params)
          msg = SymMash.new(params.delete(:msg))
          text = params.delete(:text)
          result = service.bot.send_message(msg, text, **params)
          result.to_h
        end

        r.post 'edit_message' do
          params = normalize_params(r.params)
          msg = SymMash.new(params.delete(:msg))
          id = params.delete(:id)
          service.bot.edit_message(msg, id, **params)
          {success: true}
        end

        r.post 'delete_message' do
          params = normalize_params(r.params)
          msg = SymMash.new(params.delete(:msg))
          id = params.delete(:id)
          service.bot.delete_message(msg, id, **params)
          {success: true}
        end

        r.post 'download_file' do
          params = normalize_params(r.params)
          file_id_or_info = params.delete(:file_id_or_info)
          result = service.bot.download_file(file_id_or_info, **params)
          {path: result}
        end

        r.post 'report_error' do
          params = normalize_params(r.params)
          msg = SymMash.new(params.delete(:msg))
          e = StandardError.new(params.delete(:e))
          e.define_singleton_method(:class) { OpenStruct.new(name: params.delete(:error_class)) }
          service.bot.report_error(msg, e, context: params.delete(:context))
          {success: true}
        end
      end
    end
  end
end

