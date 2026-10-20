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
      { chat_id: Integer(params.fetch(:chat_id)), retry_failed: params[:retry_failed].to_s.in?(%w[1 true]), follow: params[:follow].to_s.in?(%w[1 true]), tune: params[:tune].to_s.in?(%w[1 true]) }
    end

    # A job that follows its chat is the group's queue: the messages posted there join it (see GroupQueue).
    def standing?(job) = job.options[:follow]

    # The copies made into the chat. Those the legacy replayed log knows are judged by the bot's answers: done, failed when it
    # only answered with errors, pending when it never answered (the process died with the book).
    def seed(job)
      chat_id = job.options[:chat_id]
      replies = legacy_replies(chat_id)
      @forwarded.copies_in(chat_id).map { |copy| row(chat_id, copy[:id], replies[copy[:id]]) }
    end

    def describe(item) = @manager.message_input(chat_id: chat_id_of(item), message_id: message_id(item))

    # A message joining the queue is told how it stands once its checksum is read: a file the group already has is settled at once
    # with the link of its book, any other gets the standard "Queued" reply.
    def queued(item)
      original = original_of(item)
      return answer_duplicate(item, original) if original

      @manager.announce_queued(chat_id: chat_id_of(item), message_id: message_id(item))
      nil
    end

    # A file the group already has (the same checksum, whatever topic or message it came in) is not converted again: the item stands
    # for the earlier one, which is the first of the twins and so never a duplicate itself.
    def perform(job, item)
      original = original_of(item)
      return answer_duplicate(item, original) if original

      chat_id = job.options[:chat_id]
      id      = message_id(item)
      clear_failures(chat_id, id, item) unless @manager.message_job_active?(chat_id: chat_id, message_id: id)
      summary(chat_id, previous_answers(chat_id, id, item) || replay(chat_id, id))
    end

    # Whatever the bot answered with, there must be a book among it: nothing, errors or status lines alone are a failure.
    def error_of(result)
      return if result[:duplicate_of]

      messages = Array(result[:messages])
      return 'the bot only answered with an error' if messages.present? && messages.all? { |message| message[:failed] }

      'the bot sent no book' unless messages.any? { |message| book?(message) }
    end

    # Puts the item's wanted hashtags in the captions of the media messages that still carry other ones.
    def apply(item)
      wanted = item.outcome[:hashtags].to_s
      item.messages_dataset.live.media.exclude(failed: true).each do |message|
        recaption(message, wanted) unless message.hashtags.to_s == wanted
      end
    end

    # Generates again the hashtags of a book posted without them (see Retag) and puts them in its captions.
    def retag(item)
      item.update(result: item.outcome.merge(hashtags: Retag.new(@manager).call(item)))
      apply(item)
    end

    # Removes a tracked message from the chat.
    def delete_message(message)
      delete(message.chat_id, [message.message_id])
    end

    private

    # A message gone from the chat is no longer tracked, so the others still get their hashtags.
    def recaption(message, wanted)
      @manager.replace_caption(chat_id: message.chat_id, message_id: message.message_id, from: message.hashtags.to_s, to: wanted)
      message.update(hashtags: wanted)
    rescue => e
      raise unless e.message.match?(/not found/i)

      message.deleted!
    end

    def message_id(item) = item.key.split(':').last.to_i

    # The duplicate is answered with where its book is: the post of the original's book, or its message while it is being converted.
    def answer_duplicate(item, original)
      book = original.messages_dataset.live.media.exclude(failed: true).first
      link = book&.link || @manager.message_link(chat_id: chat_id_of(original), message_id: message_id(original))
      @manager.reply_to_message(chat_id: chat_id_of(item), message_id: message_id(item), text: "#{book ? 'Already converted' : 'Already being converted'}: #{link}")
      { duplicate_of: original.key, link: link, messages: [] }
    end

    def chat_id_of(item) = item.key.split(':').first.to_i

    # The earlier item of the job with the same file, if any; twins are the ones with the same name and size, so only those are read.
    def original_of(item)
      checksum = checksum_of(item) or return
      twins(item).find { |twin| checksum_of(twin) == checksum }
    end

    def twins(item)
      file = item.outcome[:input].to_h.slice(:file_name, :size)
      return [] if file.size < 2

      JobItem.where(kind: item.kind).where(Sequel[:id] < item.id).exclude(status: 'failed')
             .where(Sequel.pg_jsonb_op(:result).contains(input: file)).order(:id).all
    end

    # Read from the message the first time and kept with the item.
    def checksum_of(item)
      item.checksum || @manager.message_checksum(chat_id: chat_id_of(item), message_id: message_id(item)).tap { |checksum| item.update(checksum: checksum) }
    end

    # Before every run the error replies go, the tracked ones and those a dead run left that the engine never saw, and the
    # "Queued" reply: the worker posts its own status.
    def clear_failures(chat_id, id, item)
      tracked = item.messages_dataset.live.failures.select_map(:message_id)
      stale   = answers(chat_id, id).select { |message| message[:failed] || queued_status?(message) }.map { |message| message[:message_id] }
      delete(chat_id, (tracked + stale).uniq)
    end

    def queued_status?(message) = message[:kind] == 'Text' && message[:text] == Bot::UserQueue::QUEUED_MSG

    def row(chat_id, id, replies)
      messages = Array(replies).map { |message| tracked(message) }
      error    = error_of(messages: messages) if messages.present?
      { key: "#{chat_id}:#{id}", status: messages.empty? ? 'pending' : (error ? 'failed' : 'done'), error: error,
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

    # A run that died with the process may have sent the book already: keep it. When it only left errors and status lines,
    # those go and the book is converted again. Not while a worker is still converting the book: it is waited for (see
    # Manager::Service#replay_message).
    def previous_answers(chat_id, id, item)
      return if item.attempts <= 1 || @manager.message_job_active?(chat_id: chat_id, message_id: id)

      answered = answers(chat_id, id)
      return books_only(chat_id, answered) if answered.any? { |message| book?(message) }

      delete(chat_id, answered.map { |message| message[:message_id] })
      nil
    end

    def book?(message) = message[:kind] != 'Text' && !message[:failed]

    def replay(chat_id, id)
      @manager.replay_message(chat_id: chat_id, message_id: id)
      answered = answers(chat_id, id)
      answered.any? { |message| book?(message) } ? books_only(chat_id, answered) : answered
    end

    # With the book there, no status line or error reply is of use, whoever left them (a resumed book posts a new status).
    def books_only(chat_id, answered)
      books, rest = answered.partition { |message| message[:kind] != 'Text' }
      delete(chat_id, rest.map { |message| message[:message_id] })
      books
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
