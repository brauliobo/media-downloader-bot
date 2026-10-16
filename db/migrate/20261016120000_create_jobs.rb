Sequel.migration do
  change do
    create_table :jobs do
      primary_key :id
      String :kind, null: false
      String :state, null: false, default: 'queued'
      Integer :parallel, null: false, default: 1
      column :params, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      String :error, text: true
      Time :started_at
      Time :finished_at

      Time :created_at, default: Sequel.lit('now()')
      Time :updated_at, default: Sequel.lit('now()')
      index %i[kind state]
    end

    create_table :job_items do
      primary_key :id
      foreign_key :job_id, :jobs, null: false, on_delete: :cascade
      String :kind, null: false
      String :key, null: false
      String :status, null: false, default: 'pending'
      Integer :attempts, null: false, default: 0
      String :error, text: true
      column :result, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      Time :claimed_at
      Time :finished_at

      Time :created_at, default: Sequel.lit('now()')
      Time :updated_at, default: Sequel.lit('now()')
      index %i[kind key], unique: true
      index %i[job_id status id]
    end

    create_table :job_messages do
      primary_key :id
      foreign_key :job_item_id, :job_items, null: false, on_delete: :cascade
      Bignum :chat_id, null: false
      Bignum :message_id, null: false
      String :kind
      TrueClass :failed, null: false, default: false
      String :text, text: true
      String :hashtags
      String :link
      Time :deleted_at

      Time :created_at, default: Sequel.lit('now()')
      Time :updated_at, default: Sequel.lit('now()')
      index %i[chat_id message_id], unique: true
      index :job_item_id
    end
  end
end
