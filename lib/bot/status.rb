module Bot
  class Status < Array

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

      def error text, exception: nil
        @error = true
        text = "#{text}: #{exception.class}: #{exception.message}" if exception
        STDERR.puts "#{text}\n#{exception.backtrace.first(15).join("\n")}" if exception
        keep.update text
      end
    end

    def initialize(on_empty: nil, &block)
      @block    = block
      @on_empty = on_empty
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

    def error?
      @error
    end

    TELEGRAM_ERROR_LIMIT = 3500

    def error text, *args, exception: nil, **params
      @error = true
      if exception
        STDERR.puts "#{text}: #{exception.class}: #{sanitize_error(exception.message)}\n#{Array(exception.backtrace).first(20).join("\n")}"
        text = "#{text}: #{exception.class}: #{sanitize_error(exception.message)}"
      end
      send_update text, *args, **params
      nil
    end

    def sanitize_error(message)
      clean = message.to_s.encode('UTF-8', invalid: :replace, undef: :replace)
                     .gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F]/, '')
      clean.length > TELEGRAM_ERROR_LIMIT ? "#{clean[0, TELEGRAM_ERROR_LIMIT]}…" : clean
    end

    def update *args, **params
      return @on_empty&.call if blank?

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

  end
end
