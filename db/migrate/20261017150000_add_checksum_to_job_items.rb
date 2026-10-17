Sequel.migration do
  change do
    # The SHA-256 of the file a replayed message carries: the same file posted again (another topic, another message) is the same book.
    alter_table :job_items do
      add_column :checksum, String
      add_index %i[kind checksum]
    end
  end
end
