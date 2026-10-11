module Api
  # The bot's chats with whether it responds to messages there (groups are ignored until enabled)
  # and the options applied by default to their messages.
  class ChatsController < BaseController
    def index
      settings = ChatSetting.to_hash(:chat_id)
      render json: manager.list_chats(params[:q].presence).map { |chat| chat.merge(setting_json(settings[chat[:id]])) }
    end

    def update
      attrs = params.permit(:title, :options).to_h.symbolize_keys
      attrs[:respond] = ActiveModel::Type::Boolean.new.cast(params[:respond]) if params.key?(:respond)
      setting = ChatSetting.update_settings(params[:id].to_i, attrs)
      render json: { id: setting.chat_id, **setting_json(setting) }
    end

    def topics
      render json: manager.forum_topics(chat_id: params[:id].to_i)
    end

    private

    def setting_json(setting) = { respond: !!setting&.respond, options: setting&.options.to_s }
  end
end
