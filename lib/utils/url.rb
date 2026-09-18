require 'addressable/uri'

module Utils
  class Url
    HTTP_SCHEMES = %w[http https].freeze
    TOKEN_REGEXP = %r{\A(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:[/?#][^\s]*)?\z}i
    FILE_TLDS = %w[
      7z aac ass avi caf doc docx epub flac gif htm html jpeg jpg json m4a m4v
      mkv mov mp3 mp4 ogg opus pdf png ppt pptx rar srt ssa txt vtt wav webm
      webp xls xlsx yaml yml zip
    ].freeze

    def self.parse(value)
      text = value.to_s.strip
      return if text.empty?

      text = "https://#{text}" unless text.match?(%r{\Ahttps?://}i)
      uri  = Addressable::URI.parse(text)
      return unless HTTP_SCHEMES.include?(uri.scheme.to_s.downcase) && uri.host

      uri
    rescue Addressable::URI::InvalidURIError
      nil
    end

    def self.normalize(value)
      parse(value)&.to_s
    end

    def self.display(value)
      normalize(value)&.sub(%r{\Ahttps?://}i, '')&.sub(%r{\Awww\.}i, '')
    end

    def self.trailing_display_urls(text)
      text.to_s[%r{(?:\n\n(?:https?://)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:[/?#][^\s]*)?)+\z}i]
    end

    def self.token?(value)
      token = value.to_s
      return false unless token.match?(TOKEN_REGEXP)

      uri = parse(token)
      return false unless uri
      return false if file_name_host?(uri)

      uri
    end

    def self.file_name_host?(uri)
      tld = uri.host.to_s.split('.').last&.downcase
      return false unless FILE_TLDS.include?(tld)

      path = uri.path.to_s
      path.empty? || path == '/'
    end
    private_class_method :file_name_host?
  end
end
