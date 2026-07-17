require 'active_support/core_ext/module/delegation'
require_relative '../utils/safety'

module Downloaders
  class Base
    attr_reader :ctx

    delegate :url, :opts, :dir, :tmp, :st, :session, :msg, :stl, to: :ctx

    def initialize(ctx)
      @ctx = ctx
    end

    def self.build(ctx)
      new(ctx) if supports?(ctx)
    end

    def download
      raise NotImplementedError
    end

    private

    def validate_public_url!(value)
      raise ArgumentError, 'URL must resolve only to public addresses' unless Utils::Safety.public_http_url?(value)

      value
    end
  end
end
