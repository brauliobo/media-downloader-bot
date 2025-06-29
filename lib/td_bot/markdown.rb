class TDBot
  # Converts Telegram-Markdown-V2 into TD::Types::FormattedText.
  #
  # It first tries TDLib's own parser; if that fails (older TDLib build),
  # it falls back to a lightweight local parser that supports *bold* and _italic_.
  class Markdown

    class << self
      def parse(td, text)
        return TD::Types::FormattedText.new(text: '', entities: []) if text.nil?

        td.parse_text_entities(
          text: text.to_s,
          parse_mode: TD::Types::TextParseMode::Markdown.new(version: 2),
        ).value!
      rescue => e
        STDERR.puts "md_parse_error: #{e.class}: #{e.message} -- #{text.inspect}" if ENV['DEBUG']
        fallback(text)
      end

      private

      def fallback(text)
        plain    = ''.dup
        entities = []

        # regex finds *bold* or _italic_ segments (non-greedy)
        pos_utf16 = 0
        text.scan(/(\*[^*]+\*|_[^_]+_)/) do |match_arr|
          match = match_arr.first
          pre   = Regexp.last_match.pre_match[pos_utf16..-1]
          plain << pre if pre
          pos_utf16 += utf16_len(pre) if pre

          content = match[1...-1] # strip markers
          len     = utf16_len(content)
          entities << TD::Types::TextEntity.new(
            offset: pos_utf16,
            length: len,
            type: match.start_with?('*') ? TD::Types::TextEntityType::Bold.new : TD::Types::TextEntityType::Italic.new,
          )
          plain << content
          pos_utf16 += len
        end

        # append remaining tail
        tail = text.split(/(\*[^*]+\*|_[^_]+_)/, -1).last
        plain << tail if tail

        TD::Types::FormattedText.new text: plain, entities: entities
      end

      def utf16_len(str)
        str.each_char.sum { |c| c.ord > 0xFFFF ? 2 : 1 }
      end
    end

  end
end