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

    # The copies made into the chat. Those the legacy replayed log knows are judged by the bot's answers: done, failed when it
    # only answered with errors, pending when it never answered (the process died with the book).
    def seed(job)
      chat_id = job.options[:chat_id]
      replies = legacy_replies(chat_id)
      @forwarded.copies_in(chat_id).map { |copy| row(chat_id, copy[:id], replies[copy[:id]]) }
    end

    def describe(item) = @manager.message_input(chat_id: item.key.split(':').first.to_i, message_id: message_id(item))

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

    def row(chat_id, id, replies)
      messages = Array(replies).map { |message| tracked(message) }
      failed   = messages.present? && messages.all? { |message| message[:failed] }
      { key: "#{chat_id}:#{id}", status: messages.empty? ? 'pending' : (failed ? 'failed' : 'done'), error: ('the bot only answered with an error' if failed),
        result: Sequel.pg_jsonb(hashtags: wanted_hashtags(messages)), messages: messages }
    end

    # { copy id => the bot's messages answering it } for the copies the legacy log replayed.
    def legacy_replies(chat_id)
      ids = @forwarded.copies_in(chat_id).map { |copy| copy[:id] }.select { |id| @replayed.replayed?(chat_id, id) }
      return {} if ids.empty?

      answered = history(chat_id, ids.min).select { |message| ids.include?(message[:reply_to_message_id]) }.group_by { |message| message[:reply_to_message_id] }
      ids.index_with { |id| answered.fetch(id, []) }
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

    # The hashtags wanted start as the ones the bot posted in the captions of its media.
    def summary(chat_id, messages)
      { options: ChatSetting.default_options(chat_id).join(' '), hashtags: wanted_hashtags(messages), messages: messages }
    end

    def wanted_hashtags(messages) = messages.reject { |message| message[:failed] || message[:kind] == 'Text' }.filter_map { |message| message[:hashtags].presence }.join(' ')
  end
end
