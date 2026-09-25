require_relative '../../../bot/worker/http_client'

module Services
  class EditPosts
    module HTTPManager
      class Client
        def initialize(uri)
          @client = Bot::Worker::HTTPClient.new(uri)
        end

        def chat_messages(**params) = symbolize(@client.get(:chat_messages, params))
        def chat_message(**params) = symbolize(@client.get(:chat_message, params))
        def edit_generated_message(**params) = symbolize(@client.post(:edit_generated_message, params))

        def download_file(file_id_or_info, **params)
          @client.post(:download_file, params.merge(file_id_or_info: file_id_or_info))['path']
        end

        private

        def symbolize(value)
          case value
          when Array then value.map { |item| symbolize(item) }
          when Hash then value.transform_keys(&:to_sym).transform_values { |item| symbolize(item) }
          else value
          end
        end
      end
    end
  end
end
