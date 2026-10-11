module TDBot
  # Telegram deep link of a message: only supergroups and channels (-100...) have one.
  module MessageLink
    SUPERGROUP_OFFSET = 1_000_000_000_000
    SERVER_ID_SHIFT   = 20 # TDLib message ids are the server id << 20

    def self.url(chat_id:, message_id:)
      return unless chat_id < -SUPERGROUP_OFFSET

      "https://t.me/c/#{-chat_id - SUPERGROUP_OFFSET}/#{message_id >> SERVER_ID_SHIFT}"
    end
  end
end
