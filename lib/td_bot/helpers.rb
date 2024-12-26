require_relative '../msg_helpers'

class TDBot
  module Helpers

    include MsgHelpers

    TD.configure do |config|
      config.client.api_id   = ENV['TDLIB_API_ID']
      config.client.api_hash = ENV['TDLIB_API_HASH']
      config.client.database_directory = "#{Dir.pwd}/.tdlib/db"
      config.client.files_directory    = "#{Dir.pwd}/.tdlib/files"
    end
    TD::Api.set_log_verbosity_level 0

    extend ActiveSupport::Concern
    included do
      class_attribute :td, :client
      self.client = self.td = TD::Client.new timeout: 1.minute
    end

    def listen
      client.on TD::Types::Update::NewMessage do |update|
        msg = update.message
        msg = SymMash.new(
          chat: {id: msg.chat_id},
          from: {id: msg.sender_id.user_id},
          text: msg.content.text&.text,
        ).merge! msg.to_h
        STDERR.puts msg.text
        yield msg
      end
    end

    def send_message msg, text, type: 'message', chat_id: msg.chat_id
      text    = TD::Types::FormattedText.new text: text, entities: []
      content = TD::Types::InputMessageContent::Text.new clear_draft: false, text: text
      rmsg    = client.send_message(
        chat_id:               chat_id,
        input_message_content: content,
        reply_to:              nil,
        options:               {},
        reply_markup:          nil,
        message_thread_id:     nil,
      )
      rmsg.wait!
    end

    def read_state
      client.on TD::Types::Update::AuthorizationState do |update|
         @state = case update.authorization_state
                  when TD::Types::AuthorizationState::WaitPhoneNumber
                    :wait_phone_number
                  when TD::Types::AuthorizationState::WaitCode
                    :wait_code
                  when TD::Types::AuthorizationState::WaitPassword
                    :wait_password
                  when TD::Types::AuthorizationState::Ready
                    :ready
                  else
                    nil
                  end
      end
    end

    def get_supergroup_members supergroup_id: ENV['REPORT_SUPERGROUP_ID']&.to_i, chat_id: ENV['REPORT_CHAT_ID']&.to_i, limit: 200
      supergroup_id ||= td.get_chat(chat_id: chat_id).value.type.supergroup_id

      total = td.get_supergroup_members(supergroup_id: supergroup_id, filter: nil, offset: 0, limit: 1).value.total_count
      pages = (total.to_f / limit).ceil
      pages.times.flat_map do |p|
        td.get_supergroup_members(
          supergroup_id: supergroup_id, filter: nil, offset: p*limit, limit: limit,
        ).value.members
      end
    end

  end
end
