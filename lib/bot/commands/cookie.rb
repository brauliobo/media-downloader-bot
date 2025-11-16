class Manager
  module Commands
    class Cookie
      attr_reader :bot, :msg

      def initialize(bot, msg)
        @bot = bot
        @msg = msg
      end

      def process
        process_netscape_cookies
      end

      private

      def process_netscape_cookies
        cookie_content = extract_cookie_content
        return if cookie_content.nil?

        cookies_by_domain = parse_netscape_format(cookie_content)
        return if cookies_by_domain.empty?

        s = Models::Session.find_or_create uid: msg.from.id
        data = (s.cookies || {}).dup
        data.merge!(cookies_by_domain)
        s.update cookies: data
        domains_count = cookies_by_domain.keys.size
        bot.send_message msg, Bot::MsgHelpers.me("Saved #{domains_count} cookie(s) from Netscape file")
      rescue => e
        bot.report_error msg, e, context: msg.text
      end

      def extract_cookie_content
        if msg.document.present?
          local_path = bot.download_file(msg.document)
          return File.read(local_path) if local_path && File.exist?(local_path)
        end

        if msg.text.present?
          text = msg.text.strip
          text.split(/[[:space:]]+/, 2)[1] || ''
        else
          bot.send_message msg, Bot::MsgHelpers.me("Usage: /cookies (send Netscape cookie file as document or paste content)")
          nil
        end
      end

      def parse_netscape_format(content)
        cookies_by_domain = {}
        domain_cookies = {}

        content.each_line do |line|
          line = line.strip
          next if line.empty? || line.start_with?('#')

          parts = line.split("\t")
          next if parts.size < 7

          domain, _flag, _path, _secure, _expiration, name, value = parts
          next if domain.nil? || name.nil? || value.nil?

          domain = domain.sub(/^\./, '')
          cookie_pair = "#{name}=#{value}"
          domain_cookies[domain] ||= []
          domain_cookies[domain] << cookie_pair
        end

        domain_cookies.each do |domain, cookies|
          cookies_by_domain[domain] = cookies.join('; ')
        end

        cookies_by_domain
      end

    end
  end
end


