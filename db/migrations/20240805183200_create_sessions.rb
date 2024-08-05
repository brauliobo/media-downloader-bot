Sequel.migration do
  change do
    create_table :sessions do
      primary_key :uid, type: :bigint
      column :invoice, :jsonb, default: {}.to_json
      column :daylog, :jsonb, default: [].to_json

      Integer :msg_count, default: 0

      Time :created_at, default: Sequel.lit('now()')
      Time :updated_at, default: Sequel.lit('now()')
    end
  end
end
