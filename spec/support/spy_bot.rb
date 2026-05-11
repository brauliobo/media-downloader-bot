require_relative '../../lib/bot/base'

module Bot
  class Spy < Mock
    attr_reader :sent, :edited, :deleted

    def initialize
      @sent    = []
      @edited  = []
      @deleted = []
      @next_id = 0
      super
    end

    def send_message(msg, text = nil, **params)
      @next_id += 1
      @sent << SymMash.new(msg: msg, text: text, params: params, message_id: @next_id)
      SymMash.new(result: {message_id: @next_id}, message_id: @next_id, text: text)
    end

    def edit_message(msg, id, text: nil, **params)
      @edited << SymMash.new(msg: msg, id: id, text: text, params: params)
      true
    end

    def delete_message(msg, id, **_)
      @deleted << SymMash.new(msg: msg, id: id)
    end

    def download_file(info, dir:, **_)
      src = info.respond_to?(:local_path) ? info.local_path : info[:local_path]
      raise "spy_bot: download_file needs a local_path on info" unless src
      dest = File.join(dir, File.basename(src))
      FileUtils.cp(src, dest)
      dest
    end

    def report_error(*); end

    def uploads
      @sent.reject { |s| s.params.empty? }
    end
  end
end
