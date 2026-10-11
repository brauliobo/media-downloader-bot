Sequel.migration do
  change do
    create_table :chat_settings do
      primary_key :chat_id, type: :bigint, auto_increment: false
      String :title
      TrueClass :respond, null: false, default: false

      Time :created_at, default: Sequel.lit('now()')
      Time :updated_at, default: Sequel.lit('now()')
    end
  end
end
