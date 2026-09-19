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
        text = Status.report_error(text, exception) if exception
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
    BACKTRACE_LINES      = 20

    def error text, *args, exception: nil, **params
      @error = true
      text = self.class.report_error(text, exception) if exception
      send_update text, *args, **params
      nil
    end

    # Both callers name the failure the same way and print the same trace; only one of them
    # used to sanitize what it printed, which is the half worth keeping.
    def self.report_error(text, exception)
      text = "#{text}: #{exception.class}: #{sanitize_error(exception.message)}"
      STDERR.puts "#{text}\n#{Array(exception.backtrace).first(BACKTRACE_LINES).join("\n")}"
      text
    end

    def self.sanitize_error(message)
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
