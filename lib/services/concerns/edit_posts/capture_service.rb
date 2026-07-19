module Services
  class EditPosts
    module CaptureService
      class Service
        include Bot::MsgHelpers

        attr_reader :uploads

        def initialize(manager, output: $stderr)
          @manager = manager
          @output  = output
          @uploads = []
          @next_id = 1
        end

        def send_message(_msg, text = nil, type: 'message', parse_mode: 'MarkdownV2', **params)
          @uploads << { text: text, type: type.to_s, parse_mode: parse_mode, params: params } if media_upload?(type)
          @next_id += 1
          SymMash.new(message_id: @next_id, result: { message_id: @next_id }, text: text)
        end

        def edit_message(*) = true
        def delete_message(*) = true
        def download_file(...) = @manager.download_file(...)

        def report_error(_msg, error, context: nil)
          @output.puts "error: #{context} #{error.class}: #{error.message}"
        end

        private

        def media_upload?(type)
          !type.to_s.in?(%w[message text])
        end
      end
    end
  end
end
