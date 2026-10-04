require 'mechanize'
require 'net/http'

module Utils
  module Retry
    HTTP_ERRORS = [EOFError, Errno::ECONNRESET, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout].freeze
    HTTP_STATUS = %w[500 502 503 504].freeze

    module_function

    def call(tries: 4, interval: 2, multiplier: 1, on: [StandardError], retry_if: nil, on_retry: nil, sleep: true)
      n = 0
      begin
        yield
      rescue *Array(on) => error
        on_retry&.call(error)
        raise error if retry_if && !retry_if.call(error)

        n += 1
        raise error if n >= tries

        Kernel.sleep(interval * (multiplier ** (n - 1))) if sleep
        retry
      end
    end

    def http(tries: 4, interval: 2, **opts, &block)
      call(
        tries: tries, interval: interval, on: HTTP_ERRORS + [Mechanize::ResponseCodeError],
        retry_if: ->(error) { http_retryable?(error) }, on_retry: ->(*) { HTTP.reset! }, **opts, &block
      )
    end

    def tts(**opts, &block)
      call(tries: 4, interval: 0.5, multiplier: 2.0, **opts, &block)
    end

    def http_retryable?(error)
      !error.is_a?(Mechanize::ResponseCodeError) || HTTP_STATUS.include?(error.response_code.to_s)
    end
    module_function :http_retryable?
    private_class_method :http_retryable?
  end
end
