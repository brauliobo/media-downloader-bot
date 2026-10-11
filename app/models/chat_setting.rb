# Per-chat bot settings; a group without a row is ignored.
class ChatSetting < Sequel::Model(:chat_settings)
  # chat_id is the telegram chat id, not a generated value
  unrestrict_primary_key

  def self.respond?(chat_id) = !where(chat_id: chat_id, respond: true).empty?

  def self.responding = where(respond: true).select_map(:chat_id)

  # Option tokens (e.g. "lang=pt hashtags") applied to every message of the chat unless it types its own.
  def self.default_options(chat_id) = where(chat_id: chat_id).get(:options).to_s.split

  def self.update_settings(chat_id, attrs) = update_or_create({chat_id: chat_id}, attrs.compact)

  def self.set_respond(chat_id, respond, title: nil) = update_settings(chat_id, respond: respond, title: title)
end
