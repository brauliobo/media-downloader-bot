module Bot
  module MsgHelpers
    extend ActiveSupport::Concern

    ADMIN_CHAT_ID  = ENV['ADMIN_CHAT_ID']&.to_i
    REPORT_CHAT_ID = ENV['REPORT_CHAT_ID']&.to_i

    included do
      class_attribute :error_delete_time
      self.error_delete_time = 30.seconds
      class_attribute :max_caption
      self.max_caption = 1024
    end

    def msg_limit i, size: self.max_caption, percent: 100
      size = size * percent.to_f/100 if percent
      return i[0, size] if i.size > size
      i
    end

    def from_admin? msg = self.msg
      msg.from.id == ADMIN_CHAT_ID
    end
    def report_group? msg = self.msg
      msg.chat.id == REPORT_CHAT_ID
    end
    def in_group? msg = self.msg
      msg.from.id == msg.chat.id
    end

    MARKDOWN_NON_FORMAT = %w[\# / [ ] ( ) ' " ~ # + - = | { } . ! ? < >]
    MARKDOWN_FORMAT     = %w[* _ `]
    MARKDOWN_ALL        = MARKDOWN_FORMAT + MARKDOWN_NON_FORMAT

    def me t
      MARKDOWN_ALL.each{ |c| t = t.gsub c, "\\#{c}" }
      t
    end
    def mnfe t
      MARKDOWN_NON_FORMAT.each{ |c| t = t.gsub c, "\\#{c}" }
      t
    end
    def mfe t
      MARKDOWN_FORMAT.each{ |c| t = t.gsub c, "\\#{c}" }
      t
    end

    def he t
      return if t.blank?
      CGI::escapeHTML t
    end

    def parse_text(text, parse_mode:)
      return unless text
      msg_limit(text)
    end

    def fake_msg(chat_id = nil)
      SymMash.new from: {id: nil}, chat: {id: chat_id}, resp: {result: {}, text: ''}
    end

    def admin_msg
      fake_msg(ADMIN_CHAT_ID)
    end

    def report_error(msg, e, context: nil)
      return unless msg

      parts = context ? ["context: #{context.to_s.first(100)}"] : []
      parts += e.is_a?(StandardError) ? ["#{e.class}: #{e.message}", clean_bc(e.backtrace).join("\n")] : [e.to_s]
      detail = redact_sensitive(parts.compact.join("\n\n"))
      STDERR.puts "error: #{detail}"
      return send_message(msg, "<pre>#{he(detail)}</pre>", parse_mode: 'HTML', delete_both: error_delete_time) if from_admin?(msg)

      send_message(msg, me('Processing failed. The error was reported.'), delete_both: error_delete_time)
      admin_report(msg, detail)
    rescue
      send_message(msg, me('Processing failed.'), delete_both: error_delete_time) rescue nil
    end

    def admin_report(msg, _error, status: 'error')
      return unless ADMIN_CHAT_ID
      msg_ct = msg.respond_to?(:text) ? msg.text : msg.data
      error = "<b>msg</b>: #{he(redact_sensitive(msg_ct.to_s))}"
      error << "\n\n<b>#{status}</b>: <pre>#{he(_error)}</pre>\n"
      send_message(admin_msg, error, parse_mode: 'HTML')
    end

    extend self

    protected

    def clean_bc(bc)
      @bcl ||= ActiveSupport::BacktraceCleaner.new.tap { |c| c.add_filter { |line| line.gsub("#{Dir.pwd}/", '') } }
      @bcl.clean(Array(bc))
    end

    def redact_sensitive(value)
      value.to_s
           .gsub(%r{/cookies\b[^\r\n]*}i, '/cookies [REDACTED]')
           .gsub(/bot\d+:[A-Za-z0-9_-]+/, 'bot[REDACTED]')
           .gsub(/\b(authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]+/i, '\1: [REDACTED]')
           .gsub(%r{(https?://[^\s?]+)\?[^\s]+}, '\1?[REDACTED]')
    end

  end
end
