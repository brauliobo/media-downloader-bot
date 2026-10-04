module Bot
  class Album
    MAX_ITEMS = 10

    Batch = Struct.new(:uploads, :caption, keyword_init: true) do
      def items
        uploads.each_with_index.map { |upload, index| [upload, index.zero? ? caption.to_s : ''] }
      end
    end

    attr_reader :uploads, :caption

    def initialize(uploads, caption)
      @uploads = Array(uploads)
      @caption = caption
    end

    def batches
      uploads.each_slice(MAX_ITEMS).with_index.map do |batch, index|
        Batch.new(uploads: batch, caption: index.zero? ? caption : nil)
      end
    end

    def items
      batches.flat_map(&:items)
    end
  end
end
