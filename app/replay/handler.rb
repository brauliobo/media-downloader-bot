module Replay
  # Replays, as freshly received, the messages forwarded into a chat: one job item per message. Every message the bot sends for
  # it is tracked (JobMessage) with the hashtags in its caption, so a failed book is retried after deleting its error replies
  # and the hashtags can be edited later (`apply` rewrites them in the posted captions).
  class Handler < Tracked::Handler
    PARALLEL = 8
    WINDOW   = 100
    PAGE     = 100
    EXCERPT  = 500
    ERROR    = /error|failed/i
    HASHTAG  = /#\p{L}[\p{L}\p{N}_]*/

    def initialize(manager, forwarded: Forwarding::Log.new, replayed: Log.new)
      @manager   = manager
      @forwarded = forwarded
      @replayed  = replayed
    end

    def normalize(params)
      params = super
      { chat_id: Integer(params.fetch(:chat_id)), retry_failed: params[:retry_failed].to_s.in?(%w[1 true]) }
    end

    # The copies made into the chat. Those the legacy replayed log knows come in as done, unless the bot only answered them with an error.
    def seed(job)
      chat_id = job.options[:chat_id]
      failed  = failures(chat_id)
      @forwarded.copies_in(chat_id).map { |copy| row(chat_id, copy[:id], failed[copy[:id]]) }
    end

    def perform(job, item)
      chat_id = job.options[:chat_id]
      id      = message_id(item)
      delete(chat_id, item.messages_dataset.live.failures.select_map(:message_id))
      summary(chat_id, previous_answers(chat_id, id, item) || replay(chat_id, id))
    end

    def error_of(result)
      messages = result[:messages]
      'the bot only answered with an error' if messages.present? && messages.all? { |message| message[:failed] }
    end

    # Puts the item's wanted hashtags in the captions of the media messages that still carry other ones.
    def apply(item)
      wanted = item.outcome[:hashtags].to_s
      item.messages_dataset.live.media.exclude(failed: true).each do |message|
        next if message.hashtags.to_s == wanted

        @manager.replace_caption(chat_id: message.chat_id, message_id: message.message_id, from: message.hashtags.to_s, to: wanted)
        message.update(hashtags: wanted)
      end
    end

    # Removes a tracked message from the chat.
    def delete_message(message)
      delete(message.chat_id, [message.message_id])
    end

    private

    def message_id(item) = item.key.split(':').last.to_i

    def row(chat_id, id, error_messages)
      status = error_messages ? 'failed' : (@replayed.replayed?(chat_id, id) ? 'done' : 'pending')
      { key: "#{chat_id}:#{id}", status: status, error: ('the bot only answered with an error' if error_messages), result: Sequel.pg_jsonb({}),
        messages: Array(error_messages).map { |message| tracked(message) } }
    end

    # { copy id => its error messages } for the copies the legacy log replayed and the bot only answered with errors.
    def failures(chat_id)
      ids = @forwarded.copies_in(chat_id).map { |copy| copy[:id] }.select { |id| @replayed.replayed?(chat_id, id) }
      return {} if ids.empty?

      replies = history(chat_id, ids.min).select { |message| ids.include?(message[:reply_to_message_id]) }
      replies.group_by { |message| message[:reply_to_message_id] }.select { |_, group| group.all? { |message| failed?(message) } }
    end

    # The messages of the chat down to `oldest`, newest first.
    def history(chat_id, oldest)
      messages, cursor = [], 0
      loop do
        page = @manager.chat_messages(chat_id: chat_id, from_message_id: cursor, limit: PAGE)
        messages.concat(page)
        break if page.empty? || page.last[:id] <= oldest || page.last[:id] == cursor

        cursor = page.last[:id]
      end
      messages
    end

    # A run that died with the process may have answered already: keep its answers, drop its errors.
    def previous_answers(chat_id, id, item)
      return unless item.attempts > 1

      answered = answers(chat_id, id)
      delete(chat_id, answered.select { |message| message[:failed] }.map { |message| message[:message_id] })
      answered.reject { |message| message[:failed] }.presence
    end

    def replay(chat_id, id)
      @manager.replay_message(chat_id: chat_id, message_id: id)
      answers(chat_id, id)
    end

    def answers(chat_id, id) = @manager.chat_messages(chat_id: chat_id, limit: WINDOW).select { |message| message[:reply_to_message_id] == id }.map { |message| tracked(message) }

    def tracked(message)
      chat_id = message[:chat_id]
      { chat_id: chat_id, message_id: message[:id], kind: message[:type], failed: failed?(message), text: message[:text].to_s.truncate(EXCERPT),
        hashtags: message[:text].to_s.scan(HASHTAG).join(' '), link: @manager.message_link(chat_id: chat_id, message_id: message[:id]) }
    end

    def failed?(message) = message[:type] == 'Text' && message[:text].to_s.match?(ERROR)

    def delete(chat_id, ids)
      return if ids.empty?

      @manager.delete_messages(chat_id: chat_id, message_ids: ids)
      JobMessage.where(chat_id: chat_id, message_id: ids).update(deleted_at: Time.now)
    end

    # The hashtags wanted are the ones the bot posted in the captions of its media.
    def summary(chat_id, messages)
      tags = messages.reject { |message| message[:failed] || message[:kind] == 'Text' }.filter_map { |message| message[:hashtags].presence }.join(' ')
      { options: ChatSetting.default_options(chat_id).join(' '), hashtags: tags, messages: messages }
    end
  end
end
