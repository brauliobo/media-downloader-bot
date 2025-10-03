module Audiobook
  module Parsers
    class Base
      def self.parse(path, stl: nil, opts: nil)
        data = extract_data(path, stl: stl, opts: opts)
        SymMash.new(data)
      end

      def self.extract_data(path, stl: nil, opts: nil)
        raise NotImplementedError, "Subclasses must implement extract_data"
      end
    end
  end
end
