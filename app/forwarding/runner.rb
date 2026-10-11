module Forwarding
  # Copies the messages of a source chat (or forum topic) into a target one, optionally replacing their caption and
  # leaving the source afterwards. Works with any bot that implements Bot::Base::CHAT_OPERATIONS.
  class Runner
    PAGE = 100

    # source/target: {chat_id:, topic_id:}; progress receives the running counts.
    def initialize(bot, log: Log.new)
      @bot = bot
      @log = log
    end

    # plan: only count what would be copied.
    def run(source:, target:, filter: 'document', caption: nil, leave: false, plan: false, &progress)
      messages = source_messages(source, filter)
      state    = { total: messages.size, sent: 0, skipped: 0, errors: [] }
      progress&.call(state)
      return state if plan

      messages.each do |message|
        copy(source, target, message[:id], caption, state)
        progress&.call(state)
      end
      state[:left] = leave && leave_source(source, state)
      state
    end

    private

    attr_reader :bot, :log

    def copy(source, target, id, caption, state)
      return state[:skipped] += 1 if log.sent?(source, target, id)

      sent_id = bot.copy_message(from_chat_id: source[:chat_id], message_id: id, to_chat_id: target[:chat_id], topic_id: target[:topic_id], caption: caption)
      log.record(source, target, id, sent_id)
      state[:sent] += 1
    rescue => e
      state[:errors] << { id: id, error: "#{e.class}: #{e.message}" }
    end

    # Never leaves a source that still has messages that were not copied.
    def leave_source(source, state)
      return false unless state[:errors].empty?

      bot.leave_chat(chat_id: source[:chat_id])
      true
    end

    def source_messages(source, filter)
      found  = {}
      cursor = 0
      loop do
        page = bot.chat_messages(chat_id: source[:chat_id], topic_id: source[:topic_id], filter: filter, from_message_id: cursor, limit: PAGE)
        fresh = page.reject { |message| found.key?(message[:id]) }
        break if fresh.empty?

        fresh.each { |message| found[message[:id]] = message }
        cursor = fresh.map { |message| message[:id] }.min
      end
      found.values.sort_by { |message| message[:id] }
    end
  end
end
