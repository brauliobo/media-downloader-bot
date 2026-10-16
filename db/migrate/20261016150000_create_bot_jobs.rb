Sequel.migration do
  change do
    # What a bot has asked its workers to process. The row is the lease: `worker` holds it until `lease_until`, renewing it while
    # alive, so a restart of the bot (or of anything else) never loses it and a dead worker's row is simply claimable again.
    create_table :bot_jobs do
      String :id, primary_key: true
      String :queue, null: false
      String :key
      Bignum :owner_id
      Bignum :chat_id
      column :message, :jsonb, null: false, default: Sequel.lit("'{}'::jsonb")
      String :state, null: false, default: 'queued'
      TrueClass :cancelled, null: false, default: false
      String :worker
      Time :lease_until
      Integer :attempts, null: false, default: 0

      Time :created_at, default: Sequel.lit('now()')
      Time :updated_at, default: Sequel.lit('now()')
      index %i[queue state created_at]
      index %i[queue key], unique: true
    end
  end
end
