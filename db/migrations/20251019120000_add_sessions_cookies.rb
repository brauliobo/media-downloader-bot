Sequel.migration do
  change do
    alter_table :sessions do
      add_column :cookies, :jsonb, default: '{}'
    end
  end
end
