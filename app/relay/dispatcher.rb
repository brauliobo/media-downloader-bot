module Relay
  # Copies each message that matches a relay rule into the rule's target without holding the bot's reaction up: the
  # message is recorded as pending right away and copied by a small pool; whatever is left behind is retried by `recover!`.
  class Dispatcher
    POOL_SIZE    = 2
    QUEUE_SIZE   = 1_000
    STALE_AFTER  = 60
    MAX_ATTEMPTS = 3
    ERRORS       = [StandardError, NotImplementedError].freeze

    def initialize(bot_provider, pool: Concurrent::ThreadPoolExecutor.new(max_threads: POOL_SIZE, max_queue: QUEUE_SIZE, fallback_policy: :abort))
      @bot_provider = bot_provider
      @pool         = pool
    end

    # Never raises: the bot has to go on with the message whatever happens to the relay.
    def dispatch(msg)
      RelayRule.matching(msg).all.select { |rule| Filter.match?(rule.filter, msg) }.each { |rule| enqueue(rule, msg) }
    rescue *ERRORS => e
      report('dispatch', e)
    end

    def retry(id)
      ids = RelayedMessage.where(id: id).exclude(status: 'sent').select_map(:id)
      ids.each { |row_id| submit(row_id) }.any?
    end

    def retry_failed = RelayedMessage.failed.select_map(:id).each { |id| submit(id) }.size

    def recover!
      ids = RelayedMessage.stale_pending(STALE_AFTER).select_map(:id) + RelayedMessage.retryable(MAX_ATTEMPTS).select_map(:id)
      ids.each { |id| submit(id) }.size
    end

    private

    def bot = @bot_provider.call

    def enqueue(rule, msg)
      id = create_row(rule, msg)
      submit(id) if id
    end

    # nil when the message was already recorded for the rule
    def create_row(rule, msg)
      now = Time.now
      RelayedMessage.dataset.insert_conflict.insert(
        relay_rule_id: rule.id, source_chat_id: msg.chat.id, source_message_id: msg.id, target_chat_id: rule.target_chat_id,
        source_link: bot.message_link(chat_id: msg.chat.id, message_id: msg.id), content: Sequel.pg_jsonb(Summary.of(msg)),
        created_at: now, updated_at: now
      )
    end

    def submit(id) = @pool.post { perform(id) }

    def perform(id)
      row = RelayedMessage[id]
      return if row.status == 'sent'

      sent_id = copy(row)
      row.update(status: 'sent', target_message_id: sent_id, error: nil, attempts: row.attempts + 1,
                 target_link: bot.message_link(chat_id: row.target_chat_id, message_id: sent_id))
    rescue *ERRORS => e
      row&.update(status: 'failed', error: "#{e.class}: #{e.message}", attempts: row.attempts + 1)
      report("copy of relayed message #{id}", e)
    end

    def copy(row)
      rule = row.relay_rule
      bot.copy_message(from_chat_id: row.source_chat_id, message_id: row.source_message_id, to_chat_id: row.target_chat_id,
                       topic_id: rule.target_topic_id, caption: rule.caption.presence)
    end

    def report(context, error)
      warn "relay: #{context}: #{error.class}: #{error.message}"
      Rails.logger.error("relay: #{context}: #{error.full_message}")
    end
  end
end
