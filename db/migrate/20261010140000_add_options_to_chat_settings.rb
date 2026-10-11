Sequel.migration do
  change do
    alter_table(:chat_settings) { add_column :options, String, null: false, default: '' }
  end
end
