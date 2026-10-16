module Api
  # The bot's chats with whether it responds to messages there (groups are ignored until enabled),
  # the options applied by default to their messages and the queue (a following replay job) their messages wait in.
  class ChatsController < BaseController
    def index
      settings = ChatSetting.to_hash(:chat_id)
      render json: manager.list_chats(params[:q].presence).map { |chat| chat.merge(setting_json(settings[chat[:id]]), queue: Replay::GroupQueue.job_for(chat[:id])&.to_api) }
    end

    # Turns the group's queue on or off and sets how many of its messages run at once.
    def queue
      render json: manager.group_queue(chat_id: params[:id].to_i, enabled: ActiveModel::Type::Boolean.new.cast(params.require(:enabled)), parallel: params[:parallel].presence&.to_i)
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
