module Replay
  # What a message feeds the bot: what it is (Relay::Summary) and, per line of its text, the url and options the bot reads.
  module Input
    def self.of(msg)
      inputs = Utils::InputParser.message_lines(msg).map { |line| Utils::InputParser.parse(line) }
      Relay::Summary.of(msg).merge(inputs: inputs.map { |input| { url: input.url&.to_s, opts: input.opts.presence }.compact })
    end
  end
end
