# Copies what arrives in a source chat (optionally one forum topic) into a target chat (optionally a topic).
class RelayRule < Sequel::Model(:relay_rules)
  plugin :timestamps, update_on_create: true

  one_to_many :relayed_messages

  dataset_module do
    # Enabled rules watching the chat (and topic) of an incoming message; a rule without topic watches the whole chat.
    def matching(msg)
      where(enabled: true, source_chat_id: msg.chat.id).where(Sequel.|({source_topic_id: nil}, {source_topic_id: msg.topic_id.to_i}))
    end
  end

  def to_api = values.dup
end
