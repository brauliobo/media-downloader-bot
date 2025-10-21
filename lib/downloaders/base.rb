module Downloaders
  class Base
    attr_reader :processor
    delegate_missing_to :processor

    def initialize(processor)
      @processor = processor
    end

    def download
      raise NotImplementedError
    end
  end
end


