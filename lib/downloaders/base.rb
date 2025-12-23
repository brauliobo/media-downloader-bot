require 'active_support/core_ext/module/delegation'

module Downloaders
  class Base
    attr_reader :ctx

    delegate :url, :opts, :dir, :tmp, :st, :session, :msg, :stl, to: :ctx

    def initialize(ctx)
      @ctx = ctx
    end

    def download
      raise NotImplementedError
    end
  end
end
