module Services
  class EditPosts
    module HTTPManager
      class Client
        def initialize(uri)
          @client = Faraday.new(url: uri, headers: { 'Authorization' => "Bearer #{ENV.fetch('BOT_HTTP_TOKEN')}" }) do |conn|
            conn.request :json
            conn.response :json
          end
        end

        def chat_messages(**params) = get(:chat_messages, params)
        def chat_message(**params) = get(:chat_message, params)
        def edit_generated_message(**params) = post(:edit_generated_message, params)

        def download_file(file_id_or_info, **params)
          post(:download_file, params.merge(file_id_or_info: file_id_or_info))['path']
        end

        private

        def get(path, params)
          response = @client.get("/#{path}", params)
          raise "bot HTTP service returned #{response.status}" unless response.success?

          symbolize(response.body)
        end

        def post(path, params)
          response = @client.post("/#{path}", params)
          raise "bot HTTP service returned #{response.status}" unless response.success?

          symbolize(response.body)
        end

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
