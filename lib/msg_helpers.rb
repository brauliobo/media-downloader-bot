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
    return i.first size if i.size > size
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

    if e.is_a?(StandardError)
      error = ''
      error << "\n\n<b>context</b>: #{he(context.to_s.first(100))}" if context
      error << "\n\n<b>error</b>: <pre>#{he(e.class.to_s)}: #{he(e.message)}\n"
      error << "#{he(clean_bc(e.backtrace).join("\n"))}</pre>"
    else
      error = e.to_s
    end

    STDERR.puts "error: #{error}"
    send_message(msg, error, parse_mode: 'HTML', delete_both: error_delete_time)
    admin_report(msg, error) unless from_admin?(msg)
  rescue => send_err
    send_message(msg, he(error), parse_mode: 'HTML', delete_both: error_delete_time) rescue nil
  end

  def admin_report(msg, _error, status: 'error')
    return unless ADMIN_CHAT_ID
    msg_ct = msg.respond_to?(:text) ? msg.text : msg.data
    error = "<b>msg</b>: #{he(msg_ct.to_s)}"
    error << "\n\n<b>#{status}</b>: <pre>#{he(_error)}</pre>\n"
    send_message(admin_msg, error, parse_mode: 'HTML')
  end

  extend self

  protected

  def clean_bc(bc)
    @bcl ||= ActiveSupport::BacktraceCleaner.new.tap { |c| c.add_filter { |line| line.gsub("#{Dir.pwd}/", '') } }
    @bcl.clean(bc)
  end

end
