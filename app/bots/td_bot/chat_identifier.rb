require 'uri'

module TDBot
  module ChatIdentifier
    USERNAME_PATTERN = /\A[A-Za-z0-9_]{5,}\z/.freeze

    module_function

    def resolve(td, identifier)
      id = numeric_id(identifier)
      return td.get_chat(chat_id: id).value(15) if id

      username = public_username(identifier)
      raise ArgumentError, "unsupported chat identifier: #{identifier.inspect}" unless username

      td.resolve_public_chat(username)
    end

    def public_username(identifier)
      value = identifier.to_s.strip
      return if value.empty?

      value = username_from_url(value) || value.delete_prefix('@')
      value if value.match?(USERNAME_PATTERN)
    end

    def numeric_id(identifier)
      value = identifier.to_s.strip
      value.to_i if value.match?(/\A-?\d+\z/)
    end

    def username_from_url(value)
      uri = URI.parse(value)
      return uri.path.delete_prefix('/').split('/').first if uri.host&.match?(%r{\A(?:www\.)?(?:t\.me|telegram\.me)\z}i)
      return URI.decode_www_form(uri.query.to_s).to_h['domain'] if uri.scheme == 'tg' && uri.host == 'resolve'
    rescue URI::InvalidURIError
      nil
    end
  end
end
