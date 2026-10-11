Sequel.migration do
  change do
    create_table :relay_rules do
      primary_key :id
      Bignum :source_chat_id, null: false
      Bignum :source_topic_id
      String :source_title
      Bignum :target_chat_id, null: false
      Bignum :target_topic_id
      String :target_title
      String :filter, null: false, default: 'document'
      String :caption
      TrueClass :enabled, null: false, default: true

      Time :created_at, default: Sequel.lit('now()')
      Time :updated_at, default: Sequel.lit('now()')
      index %i[source_chat_id enabled]
    end

    create_table :relayed_messages do
      primary_key :id
      foreign_key :relay_rule_id, :relay_rules, null: false, on_delete: :cascade
      Bignum :source_chat_id, null: false
      Bignum :source_message_id, null: false
      String :source_link
      Bignum :target_chat_id, null: false
      Bignum :target_message_id
      String :target_link
      String :status, null: false, default: 'pending'
      Integer :attempts, null: false, default: 0
      String :error, text: true
      column :content, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")

      Time :created_at, default: Sequel.lit('now()')
      Time :updated_at, default: Sequel.lit('now()')
      index %i[relay_rule_id source_message_id], unique: true
      index %i[status created_at]
    end
  end
end
