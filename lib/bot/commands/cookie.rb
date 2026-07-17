require_relative '../../utils/cookie_jar'

class Manager
  module Commands
    class Cookie
      MAX_COOKIE_BYTES = ENV.fetch('MAX_COOKIE_BYTES', 1024 * 1024).to_i
      USAGE = 'Usage: /cookies (send Netscape cookie file as document or paste content)'.freeze

      attr_reader :bot, :msg

      def initialize(bot, msg)
        @bot = bot
        @msg = msg
      end

      def process
        cookie_content = extract_cookie_content
        return bot.send_message(msg, Bot::MsgHelpers.me(USAGE)) unless cookie_content

        cookies_by_domain = Utils::CookieJar.parse_netscape(cookie_content)
        return bot.send_message(msg, Bot::MsgHelpers.me("No cookies found. Send a Netscape cookies.txt file or paste its contents after /cookies")) if cookies_by_domain.empty?

        s = Models::Session.find_or_create uid: msg.from.id
        s.update cookies: (s.cookies || {}).merge(cookies_by_domain)
        bot.send_message msg, Bot::MsgHelpers.me("Saved #{cookies_by_domain.size} cookie(s) from Netscape file")
      rescue => e
        bot.report_error msg, e, context: 'cookie import'
      end

      private

      def extract_cookie_content
        if msg.document.present?
          size = msg.document.file_size if msg.document.respond_to?(:file_size)
          raise ArgumentError, 'cookie file is too large' if size.to_i > MAX_COOKIE_BYTES

          return Dir.mktmpdir('cookies-') do |dir|
            local_path = bot.download_file(msg.document, dir: dir)
            raise ArgumentError, 'cookie download failed' unless local_path && File.file?(local_path)
            raise ArgumentError, 'cookie file is too large' if File.size(local_path) > MAX_COOKIE_BYTES

            File.binread(local_path)
          end
        end

        text = Utils::InputParser.message_text(msg).strip
        text.split(/[[:space:]]+/, 2)[1].presence
      end

    end
  end
end
