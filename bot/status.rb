class Bot
  class Status < Array

    class Line < SimpleDelegator
      attr_accessor :status, :keep

      def update text
        self.tap do
          __setobj__ text
          status&.update
        end
      end

      def keep
        tap{ self.keep = true }
      end

      def error text
        keep.update text
      end
    end

    def initialize &block
      @block = block
    end

    def add line, &block
      line = Line.new line
      line.status = self

      append line
      update

      ret = yield line

      return ret if line.keep
      delete line 
      update

      ret
    end

    def update
      @block.call formatted
    end

    def formatted
      map(&:to_s).join "\n"
    end

  end
end
