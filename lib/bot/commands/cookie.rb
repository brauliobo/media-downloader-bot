class Manager
  module Commands
    class Cookie
      attr_reader :bot, :msg

      def initialize(bot, msg)
        @bot = bot
        @msg = msg
      end

      def process
        text = msg.text.to_s.strip
        _, domain, cookie = text.split(/[[:space:]]+/, 3)

        if domain.blank? || cookie.blank?
          return bot.send_message msg, Bot::MsgHelpers.me("Usage: /cookie <domain> <cookie>")
        end

        s = Models::Session.find_or_create uid: msg.from.id
        data = (s.cookies || {}).dup
        data[domain] = cookie
        s.update cookies: data

        bot.send_message msg, Bot::MsgHelpers.me("Cookie saved for #{domain}")
      rescue => e
        bot.report_error msg, e, context: text
      end

    end
  end
end


