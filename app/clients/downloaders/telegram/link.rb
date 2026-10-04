require 'cgi'
require 'uri'

module Downloaders
  class Telegram
    class Link
      HOSTS = %w[t.me www.t.me telegram.me www.telegram.me telegram.dog www.telegram.dog].freeze
      SLUG  = /\A[A-Za-z][A-Za-z0-9_]{3,}\z/
      ID    = /\A(\d+)/

      attr_reader :slug, :chat_id, :message_id, :url

      def self.parse(value)
        uri = URI.parse(value.to_s.strip)
        return unless uri.is_a?(URI::HTTP) && HOSTS.include?(uri.host.to_s.downcase)

        parts = uri.path.to_s.split('/').reject(&:empty?)
        parts.shift if parts.first&.casecmp('s')&.zero?
        return if parts.empty?

        query  = CGI.parse(uri.query.to_s)
        single = query.key?('single')
        link   = if parts.first == 'c' && parts[1].to_s.match?(ID)
          from_private(parts)
        else
          from_public(parts)
        end
        return unless link

        link.single = single
        link.url    = value.to_s
        link
      rescue URI::InvalidURIError
        nil
      end

      def initialize(message_id:, slug: nil, chat_id: nil)
        @message_id = message_id
        @slug       = slug
        @chat_id    = chat_id
      end

      attr_accessor :single, :url

      def private? = chat_id.present?
      def single?  = !!single

      def display_id
        "#{slug || chat_id}-#{message_id}"
      end

      def canonical_url
        return "https://t.me/c/#{chat_id}/#{message_id}" if private?

        "https://t.me/#{slug}/#{message_id}"
      end

      def embed_url
        return if private?

        query = {embed: '1'}
        query[:single] = nil if single?
        "#{canonical_url}?#{URI.encode_www_form(query)}"
      end

      def td_chat_id
        return unless private?

        "-100#{chat_id}".to_i
      end

      class << self
        private

        def from_private(parts)
          chat_id = digits(parts[1])
          msg_id  = digits(parts.last)
          return if parts.size < 3 || chat_id.nil? || msg_id.nil? || msg_id == chat_id

          new(chat_id: chat_id, message_id: msg_id)
        end

        def from_public(parts)
          slug = parts.first.to_s
          return unless slug.match?(SLUG)

          msg_id = digits(parts.last)
          return if parts.size < 2 || msg_id.nil?

          new(slug: slug, message_id: msg_id)
        end

        def digits(value)
          value.to_s[ID, 1]&.to_i
        end
      end
    end
  end
end
