require 'limiter'

class Manager
  class Status < Array
    extend Limiter::Mixin

    class Line < SimpleDelegator
      attr_accessor :status
      attr_reader :prefix, :kept

      def initialize line, prefix: nil, status: nil
        super line
        @prefix = prefix
        @status = status
        @status&.append self
        update line
      end

      def update text
        self.tap do
          text = "#{prefix}: #{text}" if prefix
          __setobj__ text
          status&.update
        end
      end

      def keep
        tap{ @kept = true }
      end

      def error?
        @error
      end

      def error text
        @error = true
        keep.update text
      end
    end

    def initialize &block
      @block = block
    end

    def add line, prefix: nil, &block
      line = Line.new line, prefix:, status: self

      ret = yield line

      return ret if line.kept
      delete line
      update

      ret
    end

    def keep?
      any?{ |l| l.kept }
    end

    def error text, *args, **params
      send_update text, *args, **params
      nil
    end

    def update *args, **params
      return if blank?
      send_update formatted, *args, **params
      nil
    end

    def formatted
      map(&:to_s).join "\n"
    end

    private

    def send_update text, *args, **params
      @block.call text, *args, **params
    end

    limit_method :send_update, rate: 30, interval: 60

  end
end
