module MsgHelpers

  MAX_CAPTION = 1024

  def self.limit i, size: MAX_CAPTION, percent: 100
    size = size * percent.to_f/100 if percent
    return i.first size if i.size > size
    i
  end

  ADMIN_CHAT_ID  = ENV['ADMIN_CHAT_ID']&.to_i
  REPORT_CHAT_ID = ENV['REPORT_CHAT_ID']&.to_i

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

  def fake_msg(chat_id = nil)
    SymMash.new from: {id: nil}, chat: {id: chat_id}, resp: {result: {}, text: ''}
  end

  extend self
end
