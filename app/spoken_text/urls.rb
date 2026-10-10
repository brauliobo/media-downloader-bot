module SpokenText
  # Spelled out, a URL is a minute of letters and slashes. Its host is the part a listener can
  # do anything with, so that is what is said.
  module Urls
    URL = %r{\b(?:https?://|www\.)([^\s/?\#]+)\S*}i

    def self.call(text) = text.to_s.gsub(URL) { Regexp.last_match(1).sub(/\Awww\./i, '') }
  end
end
