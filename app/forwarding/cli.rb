module Forwarding
  # bin/forward: resolves chats and topics by id or name and runs a forwarding against the live bot's manager (DRb),
  # so the bot keeps running; the runner itself works here.
  class CLI < CliBase
    USAGE = <<~TXT.freeze
      usage: bin/forward source=<chat id|title> [source_topic=<id|name>] target=<chat id|title> [target_topic=<id|name>]
                         [caption=lang=pt] [filter=document|audio|video|all] [leave=1] [plan=1]
    TXT

    self.progress_fields = %i[sent skipped errors total]

    def initialize(argv, log: Log.new, **)
      super(argv, **)
      @log = log
    end

    # Returns the final state: errors is empty when every message was copied.
    def run
      source = @resolver.chat_ref(@opts[:source] || abort(USAGE), @opts[:source_topic])
      target = @resolver.chat_ref(@opts[:target] || abort(USAGE), @opts[:target_topic])
      Runner.new(@manager, log: @log).run(source: source, target: target, filter: @opts[:filter] || 'document', caption: @opts[:caption],
                                          leave: flag(:leave), plan: flag(:plan)) { |state| progress(state) }
    end
  end
end
